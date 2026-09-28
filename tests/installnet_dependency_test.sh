#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
# Source only the dependency helper, never the destructive installer body.
# shellcheck disable=SC1090
source <(awk '
  /^function preflightInstallerDependencies\(\)\{/ { copy = 1 }
  copy && /^function probeInstallerResource\(\)\{/ { exit }
  copy { print }
' "$script")

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
events="$fixture/events"
mock_missing='' installed='' update_result=0 install_result=0 keep_missing=0
Relese=Debian
export INSTALLNET_FORCE_GRUB_ONCE=1

command(){
  if [[ "$1" == -v ]]; then
    if [[ " $mock_missing " == *" $2 "* && " $installed " != *" $2 "* ]]; then
      return 1
    fi
    return 0
  fi
  builtin command "$@"
}
apt-get(){
  [[ "$DEBIAN_FRONTEND" == noninteractive ]]
  printf '%s\n' "$*" >>"$events"
  if [[ "$1" == update ]]; then return "$update_result"; fi
  [[ "$1 $2 $3" == 'install -y --no-install-recommends' ]] || return 1
  (( install_result == 0 )) || return "$install_result"
  (( keep_missing )) || installed="$mock_missing"
  return 0
}
reset_case(){
  : >"$events"
  mock_missing='' installed='' update_result=0 install_result=0 keep_missing=0
}
expect_failure(){
  if preflightInstallerDependencies >"$fixture/output" 2>&1; then
    printf 'FAIL: preflight unexpectedly passed\n' >&2
    exit 1
  fi
}
expect_install(){
  [[ "$(wc -l <"$events")" == 2 ]]
  grep -Fxq update "$events"
  grep -Fxq "install -y --no-install-recommends $*" "$events"
}

reset_case
preflightInstallerDependencies >"$fixture/output"
[[ ! -s "$events" && ! -s "$fixture/output" ]]
printf 'PASS DEP1: existing dependencies invoke no apt\n'

reset_case
mock_missing=openssl
preflightInstallerDependencies >"$fixture/output"
expect_install openssl
printf 'PASS DEP2: only missing openssl installed\n'

reset_case
mock_missing=cpio
preflightInstallerDependencies >"$fixture/output"
expect_install cpio
printf 'PASS DEP3: only missing cpio installed\n'

reset_case
mock_missing='openssl cpio'
preflightInstallerDependencies >"$fixture/output"
expect_install openssl cpio
printf 'PASS DEP4: two missing packages installed in one transaction\n'

reset_case
mock_missing=openssl update_result=1
expect_failure
[[ "$(<"$events")" == update ]]
printf 'PASS DEP5: failed apt update aborts before install\n'

reset_case
mock_missing=openssl install_result=1
expect_failure
expect_install openssl
printf 'PASS DEP6: failed apt install aborts\n'

reset_case
mock_missing='openssl cpio' keep_missing=1
expect_failure
expect_install openssl cpio
grep -Fq 'Required command still unavailable: openssl' "$fixture/output"
printf 'PASS DEP7: missing command after successful apt aborts\n'

reset_case
mock_missing='ip awk cp cut stat'
preflightInstallerDependencies >"$fixture/output"
expect_install iproute2 mawk coreutils
printf 'PASS DEP9: command/package mapping deduplicates coreutils\n'

reset_case
mock_missing='openssl apt-get'
expect_failure
[[ ! -s "$events" ]]
printf 'PASS DEP10: missing apt-get aborts without apt operations\n'

# Execute just the initial main block with a harmless GRUB lookup mock.
entry=$(awk '
  /^if \[\[ "\$loaderMode" == "0" \]\]; then$/ { copy = 1 }
  copy && /^\[ -n "\$Relese" \]/ { exit }
  copy { print }
' "$script")
getGrub(){
  printf 'grub-lookup\n' >>"$events"
  printf '/fixture/grub:grub.cfg:0\n'
}
for release in 11 12; do
  reset_case
  mock_missing=openssl update_result=1
  if (
    # shellcheck disable=SC2034 # Used by the extracted main block.
    loaderMode=0 ddMode=0 tmpDIST=$release tmpVER=64
    eval "$entry"
    printf 'continued\n' >>"$events"
  ) >"$fixture/output" 2>&1; then
    printf 'FAIL: main body continued after preflight failure\n' >&2
    exit 1
  fi
  [[ "$(<"$events")" == update ]]
  printf 'PASS DEP11: Debian %s aborts before GRUB lookup or installer preparation\n' "$release"
done

reset_case
mock_missing=openssl
(
  # shellcheck disable=SC2034 # Used by the extracted main block.
  loaderMode=0 ddMode=0 Relese=CentOS
  eval "$entry"
) >"$fixture/output" 2>&1
[[ "$(<"$events")" == grub-lookup ]]
printf 'PASS DEP12: CentOS target retains the existing dependency path\n'

reset_case
mock_missing=openssl
(
  # shellcheck disable=SC2034 # Used by the extracted main block.
  loaderMode=0 ddMode=0 Relese=Ubuntu
  eval "$entry"
) >"$fixture/output" 2>&1
grep -Fxq 'install -y --no-install-recommends openssl' "$events"
printf 'PASS DEP13: Ubuntu target uses apt preflight\n'

# Substitute fixture paths only in the helper to exercise GRUB conditionals.
definition=$(declare -f preflightInstallerDependencies)
eval "$(printf '%s\n' "$definition" | sed "s#/boot/grub/#$fixture/grub/#g; s#/boot/grub2/#$fixture/grub2/#g")"
mkdir -p "$fixture/grub"
: >"$fixture/grub/grub.cfg"
reset_case
mock_missing='update-grub grub-editenv grub2-editenv'
preflightInstallerDependencies >"$fixture/output"
expect_install grub2-common grub-common
printf 'PASS DEP14: required GRUB commands map to Debian packages\n'

reset_case
mock_missing='sha256sum cmp'
preflightInstallerDependencies >"$fixture/output"
expect_install diffutils
printf 'PASS DEP15: comparison fallback required only without SHA256 tool\n'

reset_case
mock_missing=grub-editenv
preflightInstallerDependencies >"$fixture/output"
[[ ! -s "$events" ]]
printf 'PASS DEP16: existing grub2-editenv fallback avoids unnecessary install\n'
eval "$definition"

# Measure actual command lookup, not the mocks, without permitting apt.
reset_case
unset -f command apt-get
apt-get(){ printf 'unexpected apt call\n' >>"$events"; return 1; }
TIMEFORMAT='%R'
elapsed=$( { time for ((i=0; i<100; i++)); do preflightInstallerDependencies; done; } 2>&1 )
awk -v seconds="$elapsed" 'BEGIN { exit !(seconds / 100 < 1) }'
[[ ! -s "$events" ]]
awk -v seconds="$elapsed" 'BEGIN {printf "PASS DEP8: real existing-dependency lookup %.6fs/call (100 calls)\n",seconds/100}'
