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

assert_partition() {
  local disk=$1 number=$2 expected=$3 actual
  actual=$(partitionPath "$disk" "$number")
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL: partitionPath %s %s returned %s\n' "$disk" "$number" "$actual" >&2
    exit 1
  }
}

assert_partition /dev/vda 2 /dev/vda2
assert_partition /dev/sda 3 /dev/sda3
assert_partition /dev/nvme0n1 2 /dev/nvme0n1p2
assert_partition /dev/mmcblk0 3 /dev/mmcblk0p3
printf 'PASS CLOUD1: disk partition paths\n'

mkdir -p "$fixture/root"
cat >"$fixture/root/init" <<'INIT'
configure_ip() {
  true
}
# switch over to new root
INIT

lsblk() {
  printf '%s\n' 26843545600
}
interface=$(ip -4 route show default |awk '{print $5; exit}')
[[ -n "$interface" ]]
IncDisk=/dev/nvme0n1
UBUNTU_IMAGE_FILE=jammy-server-cloudimg-amd64.img
UBUNTU_IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/$UBUNTU_IMAGE_FILE"
UBUNTU_IMAGE_CHECKSUM_URL=https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS
VER=amd64
DIST=jammy
IPv4=192.0.2.10
INSTALL_PREFIX=32
GATE=192.0.2.1
ipDNS=1.1.1.1,8.8.8.8
INSTALL_USE_DHCP=0
myPASSWORD='$1$fixture$abcdefghijklmnopqrstuv'
sshPORT=22

prepareUbuntuFastInstaller "$fixture/root"
test -x "$fixture/root/installnet-ubuntu.sh"
test -x "$fixture/root/installnet-network.sh"
/bin/sh -n "$fixture/root/installnet-network.sh"
/bin/sh -n "$fixture/root/installnet-ubuntu.sh"
printf 'PASS CLOUD2: Alpine RAM installer payload prepared\n'

grep -Fq "INSTALL_DISK='/dev/nvme0n1'" "$fixture/root/installnet-ubuntu.env"
grep -Fq "EXPECTED_DISK_BYTES='26843545600'" "$fixture/root/installnet-ubuntu.env"
grep -Fq "EXPECTED_ARCH='amd64'" "$fixture/root/installnet-ubuntu.env"
grep -Fq "EXPECTED_CODENAME='jammy'" "$fixture/root/installnet-ubuntu.env"
grep -Fq 'installnet-network.sh' "$fixture/root/init"
grep -Fq 'installnet-ubuntu.start' "$fixture/root/init"
grep -Fq 'cp /reinstall.log "$sysroot/reinstall.log"' "$fixture/root/init"
grep -Fq 'stage INIT_NETWORK_START' "$fixture/root/installnet-network.sh"
grep -Fq 'stage NETWORK_READY' "$fixture/root/installnet-network.sh"
grep -Fq 'stage EFI_HANDOFF_CLEANED' "$fixture/root/installnet-ubuntu.sh"
grep -Fq 'stage RUNTIME_PACKAGE_SETUP_START' "$fixture/root/installnet-ubuntu.sh"
grep -Fq 'stage TARGET_IMAGE_DOWNLOAD_START' "$fixture/root/installnet-ubuntu.sh"
grep -Fq 'stage TARGET_IMAGE_VERIFY_DONE' "$fixture/root/installnet-ubuntu.sh"
grep -Fq 'stage TARGET_COPY_START' "$fixture/root/installnet-ubuntu.sh"
grep -Fq 'stage TARGET_RESIZE_START' "$fixture/root/installnet-ubuntu.sh"
grep -Fq 'stage BOOT_REPAIR_START' "$fixture/root/installnet-ubuntu.sh"
grep -Fq 'stage FINAL_SYNC_START' "$fixture/root/installnet-ubuntu.sh"
grep -Fq "fail 'temporary EFI handoff entry cleanup failed'" "$fixture/root/installnet-ubuntu.sh"
grep -Fq "GRUB_KERNEL_PATH='/boot/installnet-vmlinuz'" "$script"
grep -Fq 'rm -f /boot/installnet-initrd.img /boot/installnet-vmlinuz' "$script"
printf 'PASS CLOUD3: installer environment and init hooks rendered\n'

extract_line=$(grep -n '^\$UNCOMP < /tmp/\$NewIMG | cpio ' "$script" |cut -d: -f1)
prepare_line=$(grep -n '^  prepareUbuntuFastInstaller /tmp/boot ' "$script" |cut -d: -f1)
[[ "$extract_line" -lt "$prepare_line" ]]
printf 'PASS CLOUD3A: Alpine initramfs is unpacked before payload injection\n'

payload="$fixture/root/installnet-ubuntu.sh"
grep -Fq "fail 'installer root is not RAM-backed tmpfs'" "$payload"
grep -Fq "fail 'target disk is still mounted'" "$payload"
grep -Fq "fail 'cloud image size mismatch'" "$payload"
grep -Fq "fail 'cloud image SHA256 mismatch'" "$payload"
grep -Fq "fail 'verified image release mismatch'" "$payload"
grep -Fq "fail 'verified image architecture mismatch'" "$payload"
grep -Fq 'kernel_arch_matches "$kernel" "$EXPECTED_ARCH"' "$payload"
grep -Fq 'magic=$(gzip -dc "$image"' "$payload"
grep -Fq 'community_repository=${main_repository%/main}/community' "$payload"
grep -Fq 'qemu-nbd --read-only' "$payload"
grep -Fq 'mkpart root ext4' "$payload"
grep -Fq 'mkpart installer ext4' "$payload"
grep -Fq 'cp -a /source-root/. /target/' "$payload"
grep -Fq "mkfs.ext4 -F -O '^metadata_csum_seed,^orphan_file'" "$payload"
grep -Fq "fail 'Ubuntu arm64 requires UEFI firmware'" "$payload"
grep -Fq "fail 'GRUB BIOS modules missing'" "$payload"
grep -Fq 'grub-install --target=i386-pc "$INSTALL_DISK"' "$payload"
! grep -Fq 'qemu-img convert' "$payload"
! grep -Eq 'qemu-img.*"\$INSTALL_DISK"' "$payload"
printf 'PASS CLOUD4: isolated file-copy model and fail-closed checks retained\n'

source <(awk '
  /^kernel_arch_matches\(\) \{/ { copy = 1 }
  copy { print }
  copy && /^}/ { exit }
' "$payload")
arm_raw="$fixture/arm64.raw"
amd_raw="$fixture/amd64.raw"
dd if=/dev/zero of="$arm_raw" bs=1 count=60 status=none
dd if=/dev/zero of="$amd_raw" bs=1 count=518 status=none
printf ARMd |dd of="$arm_raw" bs=1 seek=56 conv=notrunc status=none
printf HdrS |dd of="$amd_raw" bs=1 seek=514 conv=notrunc status=none
gzip -c "$arm_raw" >"$arm_raw.gz"
gzip -c "$amd_raw" >"$amd_raw.gz"
kernel_arch_matches "$arm_raw" arm64
kernel_arch_matches "$arm_raw.gz" arm64
kernel_arch_matches "$amd_raw" amd64
kernel_arch_matches "$amd_raw.gz" amd64
! kernel_arch_matches "$arm_raw" amd64
! kernel_arch_matches "$amd_raw" arm64
printf 'PASS CLOUD4A: raw and gzip-wrapped kernel architecture checks fail closed\n'

sha_line=$(grep -n 'actual=.*sha256sum' "$payload" |cut -d: -f1)
format_line=$(grep -n 'mkfs.ext4 .*cloudimg-rootfs' "$payload" |cut -d: -f1)
unmount_line=$(grep -n 'unmount_tree /installer' "$payload" |cut -d: -f1)
delete_line=$(grep -n 'parted -s "\$INSTALL_DISK" -- rm 3' "$payload" |cut -d: -f1)
[[ "$sha_line" -lt "$format_line" ]]
[[ "$unmount_line" -lt "$delete_line" ]]
printf 'PASS CLOUD5: checksum precedes target write and staging deletion follows unmount\n'

success_line=$(grep -n "Ubuntu fast image installation verified; rebooting" "$payload" |cut -d: -f1)
log_copy_line=$(grep -n 'cp /reinstall.log /target/var/log/installnet-ubuntu.log' "$payload" |cut -d: -f1)
[[ "$success_line" -lt "$log_copy_line" ]]
printf 'PASS CLOUD5A: final success state is retained in target log\n'

network="$fixture/root/installnet-network.sh"
grep -Fq 'ip -4 addr add "$IPV4/$PREFIX"' "$network"
grep -Fq 'ip -4 route replace "$GATEWAY/32" dev "$iface" scope link' "$network"
grep -Fq 'ip -4 route replace default via "$GATEWAY" dev "$iface"' "$network"
grep -Fq 'dhcp4: true' "$payload"
grep -Fq 'on-link: true' "$payload"
printf 'PASS CLOUD6: DHCP, static and /32 off-link routing retained\n'

for release in jammy noble; do
  for arch in amd64 arm64; do
    file="${release}-server-cloudimg-${arch}.img"
    checksum=$(wget --no-check-certificate -qO- \
      "https://cloud-images.ubuntu.com/${release}/current/SHA256SUMS" |
      awk -v name="*$file" '$2 == name {print $1; exit}')
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]]
  done
done
printf 'PASS CLOUD7: Jammy/Noble AMD64/ARM64 official checksum metadata resolved\n'
