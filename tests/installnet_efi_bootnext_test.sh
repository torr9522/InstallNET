#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

source <(awk '
  /^function getGrub\(\)\{/ { copy = 1 }
  copy && /^if \[\[ "\$loaderMode" == "0" \]\]; then$/ { exit }
  copy { print }
' "$script")

mkdir -p "$fixture/efi" "$fixture/source"
kernel="$fixture/source/grubaa64.efi"
truncate -s 2097152 "$kernel"
printf 'MZ' |dd of="$kernel" bs=1 conv=notrunc status=none
printf '\x40\x00\x00\x00' |dd of="$kernel" bs=1 seek=60 conv=notrunc status=none
printf 'PE\x00\x00\x64\xaa' |dd of="$kernel" bs=1 seek=64 conv=notrunc status=none

INSTALLNET_HANDOFF_LOG="$fixture/handoff.log"
INSTALLNET_ARM64_GRUB_EFI_URL=https://example.invalid/grubaa64.efi
INSTALLNET_ARM64_GRUB_EFI_SHA256=$(sha256sum "$kernel" |awk '{print $1}')
INSTALL_ENTRY_TITLE='Install OS [noble arm64]'
GRUB_KERNEL_PATH=/boot/installnet-vmlinuz
GRUB_INITRD_PATH=/boot/installnet-initrd.img
BOOT_OPTION='alpine_repo=https://example.invalid/main ip=dhcp'

findmnt() {
  case "$*" in
    '-n -o TARGET /boot/efi') printf '%s\n' "$fixture/efi" ;;
    '-n -o SOURCE --target '*) printf '%s\n' /dev/sda1 ;;
    *) return 1 ;;
  esac
}
lsblk() {
  case "$*" in
    '-ndo PKNAME /dev/sda1') printf '%s\n' sda ;;
    *) return 1 ;;
  esac
}
wget() {
  local output=''
  while (($#)); do
    if [[ "$1" == -qO ]]; then output=$2; shift 2; else shift; fi
  done
  cp "$kernel" "$output"
}
efibootmgr() {
  case "${1:-}" in
    --create-only) touch "$fixture/entry" ;;
    --bootnum) rm -f "$fixture/entry" ;;
    --bootnext) printf '%s\n' "$2" >"$fixture/bootnext" ;;
    *)
      [[ ! -f "$fixture/bootnext" ]] || printf 'BootNext: %s\n' "$(<"$fixture/bootnext")"
      [[ ! -f "$fixture/entry" ]] || printf 'Boot0007* InstallNET one-shot\n'
      ;;
  esac
}

prepareInstallnetEfiBoot
test "$(<"$fixture/bootnext")" = 0007
test -s "$fixture/efi/EFI/installnet/grubaa64.efi"
grep -Fq 'linux /boot/installnet-vmlinuz' "$fixture/efi/EFI/installnet/grub.cfg"
grep -Fq '[PASS] firmware BootNext 0007' "$INSTALLNET_HANDOFF_LOG"
printf 'PASS EFI1: verified independent GRUB and firmware BootNext\n'

INSTALLNET_ARM64_GRUB_EFI_SHA256=00
if prepareInstallnetEfiBoot >"$fixture/output" 2>&1; then
  printf 'unexpected success with wrong EFI GRUB checksum\n' >&2
  exit 1
fi
grep -Fq 'EFI GRUB SHA256 mismatch' "$fixture/output"
printf 'PASS EFI2: wrong independent GRUB checksum fails closed\n'
