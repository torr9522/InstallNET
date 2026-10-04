#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

# Source only the cloud-image preparation helpers, never the installer main body.
source <(awk '
  /^function prepareCloudImageInstaller\(\)\{/ { copy = 1 }
  copy { print }
  copy && /^function partitionPath\(\)\{/ { in_partition = 1 }
  in_partition && /^}/ { exit }
' "$script")

assert_partition() {
  local disk=$1 number=$2 expected=$3 actual
  actual=$(partitionPath "$disk" "$number")
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL: partitionPath %s %s returned %s\n' "$disk" "$number" "$actual" >&2
    exit 1
  }
}

assert_partition /dev/vda 1 /dev/vda1
assert_partition /dev/sda 15 /dev/sda15
assert_partition /dev/nvme0n1 1 /dev/nvme0n1p1
assert_partition /dev/mmcblk0 15 /dev/mmcblk0p15
printf 'PASS CLOUD1: disk partition paths\n'

interface=$(ip -4 route show default |awk '{print $5; exit}')
[[ -n "$interface" ]]
IncDisk=/dev/nvme0n1
CLOUD_IMAGE_FILE=jammy-server-cloudimg-amd64.img
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/$CLOUD_IMAGE_FILE"
CLOUD_IMAGE_CHECKSUM_URL=https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS
VER=amd64
DIST=jammy
IPv4=192.0.2.10
INSTALL_PREFIX=32
GATE=192.0.2.1
ipDNS=1.1.1.1
INSTALL_USE_DHCP=0
myPASSWORD='$1$fixture$abcdefghijklmnopqrstuv'
sshPORT=22

prepareCloudImageInstaller "$fixture/root"
test -x "$fixture/root/installnet-qemu/qemu-img"
test -x "$fixture/root/installnet-qemu/sfdisk"
test -s "$fixture/root/installnet-qemu/modules/block-curl.so"
test -s "$fixture/root/etc/ssl/certs/ca-certificates.crt"
test -x "$fixture/root/installnet-cloud-install.sh"
/bin/sh -n "$fixture/root/installnet-cloud-install.sh"
printf 'PASS CLOUD2: portable qemu bundle and installer payload prepared\n'

grep -Fq "ROOT_PARTITION='/dev/nvme0n1p1'" "$fixture/root/installnet-cloud.env"
grep -Fq "EFI_PARTITION='/dev/nvme0n1p15'" "$fixture/root/installnet-cloud.env"
grep -Fq "EXPECTED_ARCH='amd64'" "$fixture/root/installnet-cloud.env"
grep -Fq "EXPECTED_CODENAME='jammy'" "$fixture/root/installnet-cloud.env"
printf 'PASS CLOUD3: cloud installer environment rendered\n'

payload="$fixture/root/installnet-cloud-install.sh"
! grep -Eq '(^|[|[:space:]])tee([[:space:]]|$)' "$payload"
grep -Fq '/etc/ssh/sshd_config.d/00-installnet.conf' "$payload"
grep -Fq "fail 'cloud image SHA256 mismatch'" "$payload"
grep -Fq "fail 'cloud image and verified staging area do not fit target disk'" "$payload"
grep -Fq "sfdisk_cmd --wipe always" "$payload"
grep -Fq 'wget -nv -O "$ROOT_PARTITION" "$IMAGE_URL"' "$payload"
grep -Fq 'qemu_img convert -f qcow2 -O raw "$ROOT_PARTITION" "$INSTALL_DISK"' "$payload"
grep -Fq "fail 'target cloud image release mismatch'" "$payload"
grep -Fq "fail 'target kernel architecture mismatch'" "$payload"
grep -Fq "fail 'AMD64 EFI fallback missing'" "$payload"
grep -Fq "fail 'ARM64 EFI fallback missing'" "$payload"
printf 'PASS CLOUD4: fail-closed checks and early SSH override retained\n'

loader=$(sed -n "s/^QEMU_LOADER='\(.*\)'/\1/p" "$fixture/root/installnet-cloud.env")
QEMU_MODULE_DIR="$fixture/root/installnet-qemu/modules" \
  "$fixture/root/installnet-qemu/lib/$loader" \
  --library-path "$fixture/root/installnet-qemu/lib" \
  "$fixture/root/installnet-qemu/qemu-img" info "$CLOUD_IMAGE_URL" |
  grep -Fq 'file format: qcow2'
printf 'PASS CLOUD5: isolated qemu bundle reads official HTTPS image\n'

checksum=$(wget --no-check-certificate -qO- "$CLOUD_IMAGE_CHECKSUM_URL" |
  awk -v file="*$CLOUD_IMAGE_FILE" '$2 == file {print $1; exit}')
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]]
printf 'PASS CLOUD6: official image checksum metadata resolved\n'
