#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

source <(awk '
  /^function prepareUbuntuFastInstaller\(\)\{/ { copy = 1 }
  copy { print }
  copy && /^function partitionPath\(\)\{/ { in_partition = 1 }
  in_partition && /^}/ { exit }
' "$script")

mkdir -p "$fixture/root"
cat >"$fixture/root/init" <<'INIT'
configure_ip() {
  true
}
# switch over to new root
INIT

lsblk() { printf '%s\n' 26843545600; }
interface=$(ip -4 route show default |awk '{print $5; exit}')
IncDisk=/dev/vda
UBUNTU_IMAGE_FILE=noble-server-cloudimg-amd64.img
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/$UBUNTU_IMAGE_FILE"
UBUNTU_IMAGE_CHECKSUM_URL=https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
VER=amd64
DIST=noble
IPv4=192.0.2.10
INSTALL_PREFIX=32
GATE=192.0.2.1
ipDNS=1.1.1.1,8.8.8.8
INSTALL_USE_DHCP=0
myPASSWORD='$1$fixture$abcdefghijklmnopqrstuv'
sshPORT=22

prepareUbuntuFastInstaller "$fixture/root"
payload="$fixture/root/installnet-ubuntu.sh"

grep -Fq ': >/target/etc/machine-id' "$payload"
! grep -Fq 'uninitialized >/target/etc/machine-id' "$payload"
grep -Fq "[ -f /target/etc/machine-id ] && [ ! -s /target/etc/machine-id ]" "$payload"
grep -Fq "fail 'target machine-id must be an empty regular file before first boot'" "$payload"
grep -Fq "[ -f /target/etc/cloud/cloud-init.disabled ]" "$payload"
grep -Fq 'chroot /target netplan generate' "$payload"
grep -Fq 'chroot /target systemctl is-enabled ssh.service' "$payload"

machine_line=$(grep -n ': >/target/etc/machine-id' "$payload" |cut -d: -f1)
validate_line=$(grep -n '^validate_target_first_boot$' "$payload" |cut -d: -f1)
reboot_line=$(grep -n '^reboot$' "$payload" |cut -d: -f1)
[[ "$machine_line" -lt "$validate_line" && "$validate_line" -lt "$reboot_line" ]]

printf 'PASS MACHINE-ID1: configured images use empty machine-id without first-boot semantics\n'
printf 'PASS MACHINE-ID2: target configuration is validated before reboot\n'
