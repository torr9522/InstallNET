#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
output_dir=/root/installnet-debian12-audit/phase2
mkdir -p "$output_dir"
source <(awk '
  /^function dependence\(\)\{/ { copy = 1 }
  copy && /^if \[\[ "\$loaderMode" == "0" \]\]; then$/ { exit }
  copy { print }
' "$script")

export interfaceSelect=auto ipDNS=8.8.8.8 MirrorHost=deb.debian.org
export MirrorFolder=/debian sshPORT=22 SelectLowmem= DDURL= setCMD=
export myPASSWORD='[REDACTED_EXAMPLE_MD5_HASH]'
linux_relese=debian ddMode=0 loaderMode=0 setNet=0 INSTALL_USE_DHCP=0

render() {
  local out="$1"
  # Evaluate only the original heredoc. Do not execute installer operations.
  awk '
    /^cat >\/tmp\/boot\/preseed.cfg<<EOF$/ { copy = 1 }
    copy { print }
    copy && /^EOF$/ { exit }
  ' "$script" | sed "s@/tmp/boot/preseed.cfg@$out@" | bash
  sed -i '/user-setup\/allow-password-weak/d; /user-setup\/encrypt-home/d; /pkgsel\/update-policy/d' "$out"
  sed -i 's/umount\ \/media.*true\;\ //g; /anna-install/d; s/wget.*\/sbin\/reboot\;\ //g' "$out"
  applyDebianP1Preseed "$out"
  debconf-set-selections -c "$out"
}

check_static() {
  local out=$1 disk=$2
  grep -Fxq "d-i netcfg/get_ipaddress string $IPv4" "$out"
  grep -Fxq "d-i netcfg/get_netmask string $MASK" "$out"
  grep -Fxq "d-i netcfg/get_gateway string $GATE" "$out"
  grep -Fxq "d-i mirror/http/hostname string $MirrorHost" "$out"
  grep -Fxq "d-i mirror/http/directory string $MirrorFolder" "$out"
  grep -Fxq "d-i partman-auto/disk string $disk" "$out"
  grep -Fxq "d-i grub-installer/bootdev string $disk" "$out"
  grep -Fq "grep -Fxq -- '$disk' && debconf-set partman-auto/disk '$disk'" "$out"
}

IPv4=10.0.0.10 MASK=255.255.255.255 GATE=10.0.0.1 IncDisk=/dev/vdb
export IPv4 MASK GATE IncDisk
render "$output_dir/DEBIAN12_PRESEED_AFTER_FIX.txt"
check_static "$output_dir/DEBIAN12_PRESEED_AFTER_FIX.txt" /dev/vdb
printf 'PASS Bookworm /32 preseed, mirror and consistent /dev/vdb\n'

IPv4=192.0.2.10 MASK=255.255.255.0 GATE=192.0.2.1 IncDisk=/dev/vda
export IPv4 MASK GATE IncDisk
render "$output_dir/DEBIAN11_PRESEED_AFTER_FIX.txt"
check_static "$output_dir/DEBIAN11_PRESEED_AFTER_FIX.txt" /dev/vda
printf 'PASS Bullseye /24 preseed, mirror and consistent /dev/vda\n'

INSTALL_USE_DHCP=1
render "$output_dir/DEBIAN12_DHCP_PRESEED_AFTER_FIX.txt"
! grep -q '^d-i netcfg/get_ipaddress\|^d-i netcfg/disable_autoconfig' "$output_dir/DEBIAN12_DHCP_PRESEED_AFTER_FIX.txt"
grep -Fxq 'd-i partman-auto/disk string /dev/vda' "$output_dir/DEBIAN12_DHCP_PRESEED_AFTER_FIX.txt"
printf 'PASS DHCP preseed keeps automatic network configuration\n'

setNet=1
render "$output_dir/DEBIAN12_EXPLICIT_IP_PRESEED_AFTER_FIX.txt"
check_static "$output_dir/DEBIAN12_EXPLICIT_IP_PRESEED_AFTER_FIX.txt" /dev/vda
printf 'PASS explicit static IP overrides host DHCP detection\n'
