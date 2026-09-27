#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

# The main body installs an OS. Only definitions preceding it may be sourced.
source <(awk '
  /^function dependence\(\)\{/ { copy = 1 }
  copy && /^if \[\[ "\$loaderMode" == "0" \]\]; then$/ { exit }
  copy { print }
' "$script")

assert_eq() {
  [[ "$1" == "$2" ]] || { printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }
}
assert_failure() {
  if "$@" >"$fixture/output" 2>&1; then
    printf 'unexpected success: %s\n' "$*" >&2
    exit 1
  fi
}

ip() {
  case "$*" in
    '-4 route show default') printf '%s\n' "$TEST_ROUTES" ;;
    '-4 -o addr show dev '*' scope global')
      local dev=${6}
      case "$dev" in
        "$TEST_IFACE") printf '2: %s inet %s brd + scope global %s %s\n' \
          "$dev" "$TEST_ADDRESS" "$TEST_ADDR_FLAGS" "$dev" ;;
        *) printf '3: %s inet 203.0.113.5/24 scope global %s\n' "$dev" "$dev" ;;
      esac ;;
    '-6 route show default') printf '%s\n' "${TEST_IPV6_ROUTE:-}" ;;
    *) printf 'unexpected ip invocation: %s\n' "$*" >&2; return 1 ;;
  esac
}

check_network() {
  local label=$1 iface=$2 address=$3 gateway=$4 mask=$5
  local dhcp=${6:-0}
  detectInstallNetwork
  assert_eq "$INSTALL_IFACE" "$iface"
  assert_eq "$INSTALL_IPV4" "${address%/*}"
  assert_eq "$INSTALL_PREFIX" "${address#*/}"
  assert_eq "$INSTALL_NETMASK" "$mask"
  assert_eq "$INSTALL_GATEWAY" "$gateway"
  assert_eq "$INSTALL_USE_DHCP" "$dhcp"
  printf 'PASS %s\n' "$label"
}

TEST_ADDR_FLAGS= TEST_IFACE=ens3 TEST_ADDRESS=192.0.2.10/24
TEST_ROUTES='default via 192.0.2.1 dev ens3 metric 100'
check_network N1 ens3 192.0.2.10/24 192.0.2.1 255.255.255.0
TEST_ADDRESS=198.51.100.10/32 TEST_ROUTES='default via 198.51.100.1 dev ens3 onlink'
check_network N2 ens3 198.51.100.10/32 198.51.100.1 255.255.255.255
TEST_ADDRESS=10.0.0.10/32 TEST_ROUTES='default via 10.0.0.1 dev ens3 onlink'
check_network N3 ens3 10.0.0.10/32 10.0.0.1 255.255.255.255
TEST_IFACE=eth1 TEST_ADDRESS=192.0.2.11/24
TEST_ROUTES=$'default via 203.0.113.1 dev eth0 metric 200\ndefault via 192.0.2.1 dev eth1 metric 100'
check_network N4 eth1 192.0.2.11/24 192.0.2.1 255.255.255.0
check_network N5 eth1 192.0.2.11/24 192.0.2.1 255.255.255.0
TEST_IFACE=ens3 TEST_ROUTES='default via 192.0.2.1 dev ens3'
check_network N6 ens3 192.0.2.11/24 192.0.2.1 255.255.255.0
TEST_IFACE=enp1s0 TEST_ROUTES='default via 192.0.2.1 dev enp1s0'
check_network N7 enp1s0 192.0.2.11/24 192.0.2.1 255.255.255.0
# IPv6 output is irrelevant to explicit IPv4 route/address queries.
TEST_IPV6_ROUTE='default via 2001:db8::1 dev enp1s0'
check_network N8 enp1s0 192.0.2.11/24 192.0.2.1 255.255.255.0
TEST_IPV6_ROUTE='default via 2001:db8::bad dev enp1s0'
check_network N9 enp1s0 192.0.2.11/24 192.0.2.1 255.255.255.0
TEST_ADDR_FLAGS=dynamic TEST_ROUTES='default via 192.0.2.1 dev enp1s0 proto dhcp metric 100'
check_network N10 enp1s0 192.0.2.11/24 192.0.2.1 255.255.255.0 1
TEST_ROUTES=$'default via 192.0.2.1 dev enp1s0 metric 100\ndefault via 198.51.100.1 dev eth0 metric 100'
assert_failure detectInstallNetwork
printf 'PASS N-ambiguous: equal metrics rejected\n'

findmnt() {
  [[ "$*" == '-n -o SOURCE /' ]] || return 1
  printf '%s\n' "$TEST_ROOT_SOURCE"
}
lsblk() {
  [[ "$*" == "-srnpo NAME,TYPE -- $TEST_ROOT_SOURCE" ]] || return 1
  printf '%s\n' "$TEST_DISK_CHAIN"
}
check_disk() {
  local label=$1 expected=$2
  assert_eq "$(getRootDisk)" "$expected"
  printf 'PASS %s\n' "$label"
}
TEST_ROOT_SOURCE=/dev/vda1 TEST_DISK_CHAIN=$'/dev/vda1 part\n/dev/vda disk'
check_disk D1 /dev/vda
TEST_ROOT_SOURCE=/dev/sda2 TEST_DISK_CHAIN=$'/dev/sda2 part\n/dev/sda disk'
check_disk D2 /dev/sda
TEST_ROOT_SOURCE=/dev/nvme0n1p2 TEST_DISK_CHAIN=$'/dev/nvme0n1p2 part\n/dev/nvme0n1 disk'
check_disk D3 /dev/nvme0n1
TEST_ROOT_SOURCE=/dev/vdb1 TEST_DISK_CHAIN=$'/dev/vdb1 part\n/dev/vdb disk'
check_disk D4 /dev/vdb
TEST_ROOT_SOURCE=/dev/nvme0n1p2 TEST_DISK_CHAIN=$'/dev/nvme0n1p2 part\n/dev/nvme0n1 disk'
check_disk D5 /dev/nvme0n1
TEST_ROOT_SOURCE=/dev/vda1 TEST_DISK_CHAIN=$'/dev/vda1 part\n/dev/vda disk'
check_disk D6 /dev/vda
TEST_ROOT_SOURCE=/dev/mapper/vg-root
TEST_DISK_CHAIN=$'/dev/mapper/vg-root lvm\n/dev/nvme0n1p2 part\n/dev/nvme0n1 disk'
check_disk D-LVM /dev/nvme0n1
TEST_ROOT_SOURCE=/dev/mapper/vg-root
TEST_DISK_CHAIN=$'/dev/mapper/vg-root lvm\n/dev/vda2 part\n/dev/vda disk\n/dev/vdb2 part\n/dev/vdb disk'
assert_failure getRootDisk
printf 'PASS D-ambiguous: multiple physical disks rejected\n'

GRUBDIR="$fixture/grub" GRUBFILE=grub.cfg GRUBVER=0
INSTALL_ENTRY_TITLE='Install OS [bookworm amd64]'
INSTALLNET_HANDOFF_LOG="$fixture/handoff.log"
mkdir -p "$GRUBDIR"
commandExists() {
  case "$1" in
    grub-reboot) [[ "$MOCK_REBOOT_AVAILABLE" == 1 ]] ;;
    grub-editenv) [[ "$MOCK_ED_EDIT" == 1 ]] ;;
    grub2-editenv) [[ "$MOCK_ED2_EDIT" == 1 ]] ;;
    *) return 1 ;;
  esac
}
grub-reboot() {
  [[ "$MOCK_REBOOT_RESULT" == 0 ]] || return 1
  [[ -f "$GRUBDIR/grubenv" ]] || return 0
  case "$MOCK_NEXT" in
    correct) printf 'next_entry=%s\n' "${*: -1}" >"$GRUBDIR/grubenv" ;;
    wrong) printf 'next_entry=Old OS\n' >"$GRUBDIR/grubenv" ;;
    absent) printf 'saved_entry=Old OS\n' >"$GRUBDIR/grubenv" ;;
  esac
}
grub2-reboot() { grub-reboot "$@"; }
mock_editenv() {
  local envfile=$1 action=$2
  case "$action" in
    list) cat "$envfile" ;;
    set) printf '%s\n' "$3" >"$envfile" ;;
    *) return 1 ;;
  esac
}
grub-editenv() { mock_editenv "$@"; }
grub2-editenv() { mock_editenv "$@"; }
check_grub() {
  local label=$1 expect=$2
  if [[ "$expect" == pass ]]; then
    scheduleGrubOnceBoot "$INSTALL_ENTRY_TITLE"
    assert_eq "$(sed -n 's/^next_entry=//p' "$GRUBDIR/grubenv")" "$INSTALL_ENTRY_TITLE"
  else
    assert_failure scheduleGrubOnceBoot "$INSTALL_ENTRY_TITLE"
  fi
  printf 'PASS %s\n' "$label"
}
MOCK_REBOOT_AVAILABLE=1 MOCK_REBOOT_RESULT=0 MOCK_ED_EDIT=1 MOCK_ED2_EDIT=0 MOCK_NEXT=correct
printf 'load_env\nif [ "${next_entry}" ]; then set default="${next_entry}"; fi\nmenuentry '\''%s'\'' { true; }\n' "$INSTALL_ENTRY_TITLE" >"$GRUBDIR/grub.cfg"
: >"$GRUBDIR/grubenv"
check_grub G1 pass
check_grub G2 pass
MOCK_NEXT=absent
rm "$GRUBDIR/grubenv"
check_grub G3 fail
: >"$GRUBDIR/grubenv"
check_grub G4 fail
MOCK_NEXT=wrong
check_grub G4-wrong fail
MOCK_NEXT=correct
check_grub G5 pass
check_grub G6 pass
MOCK_ED_EDIT=0 MOCK_ED2_EDIT=1
mkdir -p "$fixture/grub2"
cp "$GRUBDIR/grub.cfg" "$GRUBDIR/grubenv" "$fixture/grub2/"
GRUBDIR="$fixture/grub2"
check_grub G7 pass
MOCK_REBOOT_AVAILABLE=0
check_grub G8 pass
GRUBDIR="$fixture/grub"
MOCK_REBOOT_AVAILABLE=1 MOCK_ED_EDIT=1 MOCK_ED2_EDIT=0
printf 'load_env\nif [ "${next_entry}" ]; then set default="${next_entry}"; elif [ "${saved_entry}" ]; then set default="${saved_entry}"; fi\nmenuentry '\''%s'\'' { true; }\n' "$INSTALL_ENTRY_TITLE" >"$GRUBDIR/grub.cfg"
check_grub G9 pass
printf 'load_env\nif [ "${next_entry}" ]; then set default="${next_entry}"; else set default=0; fi\nmenuentry '\''%s'\'' { true; }\n' "$INSTALL_ENTRY_TITLE" >"$GRUBDIR/grub.cfg"
check_grub G10 pass
if command -v grub-script-check >/dev/null 2>&1; then
  grub-script-check "$GRUBDIR/grub.cfg"
fi
printf 'menuentry '\''%s'\'' { true; }\n' "$INSTALL_ENTRY_TITLE" >"$GRUBDIR/grub.cfg"
check_grub G-no-load-env fail

MOCK_MIRROR_MODE=fast
wget() {
  printf '%s\n' "$*" >>"$fixture/wget.calls"
  case "$*" in
    *'/dists/'|*'/dists/') return 8 ;;
  esac
  case "$MOCK_MIRROR_MODE" in
    fast|redirect|https) return 0 ;;
    slow)
      if [[ ! -f "$fixture/retried" ]]; then touch "$fixture/retried"; return 4; fi
      return 0 ;;
    ipv6)
      [[ " $* " == *' --inet4-only '* ]] || return 4 ;;
    missing) return 8 ;;
  esac
}
check_mirror() {
  local label=$1 mode=$2
  MOCK_MIRROR_MODE=$mode
  : >"$fixture/wget.calls"
  assert_eq "$(selectMirror debian bookworm amd64 'https://mirror.example/debian')" 'https://mirror.example/debian'
  grep -q '/linux' "$fixture/wget.calls"
  grep -q '/initrd.gz' "$fixture/wget.calls"
  printf 'PASS %s\n' "$label"
}
check_mirror M1 fast
check_mirror M2 slow
[[ "$(wc -l < "$fixture/wget.calls")" -ge 3 ]]
check_mirror M3 ipv6
grep -q -- '--inet4-only' "$fixture/wget.calls"
check_mirror M4 redirect
check_mirror M5 https
check_mirror M6 fast
MOCK_MIRROR_MODE=missing
probe_missing_mirror() ( selectMirror debian bookworm amd64 'https://mirror.example/debian' )
assert_failure probe_missing_mirror
grep -q 'RESOURCE_NOT_FOUND' "$fixture/output"
printf 'PASS M-404: resource absence reported separately\n'
if grep -q -- '--timeout=3' "$fixture/wget.calls"; then
  printf 'mirror still uses 3-second timeout\n' >&2
  exit 1
fi
printf 'PASS all P1 fixtures\n'
