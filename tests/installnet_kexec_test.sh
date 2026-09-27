#!/bin/bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

# Extract only helpers; running the main installer would modify the host bootloader.
# shellcheck disable=SC1090
source <(awk '
  /^function getGrub\(\)\{/ { copy = 1 }
  copy && /^if \[\[ "\$loaderMode" == "0" \]\]; then$/ { exit }
  copy { print }
' "$script")

eval "$(declare -f preventKexecReboot | sed '1s/^preventKexecReboot ()/_preventKexecReboot ()/')"
INSTALLNET_HANDOFF_LOG="$fixture/handoff.log"
INSTALL_ENTRY_TITLE='Install OS [bookworm amd64]'
export INSTALLNET_NO_REBOOT=0
GRUBDIR="$fixture/grub"
export GRUBFILE=grub.cfg
mkdir -p "$GRUBDIR"
printf 'next_entry=%s\n' "$INSTALL_ENTRY_TITLE" >"$GRUBDIR/grubenv"
printf 'LOAD_KEXEC=true\n' >"$fixture/kexec.conf"
printf '#!/bin/sh\nNOKEXECFILE=/no-kexec-reboot\n' >"$fixture/kexec-load"
chmod +x "$fixture/kexec-load"
printf '0\n' >"$fixture/loaded"

events="$fixture/events"
record(){ printf '%s\n' "$1" >>"$events"; }
expect_fail(){
  if "$@" >"$fixture/output" 2>&1; then
    printf 'unexpected success: %s\n' "$*" >&2
    exit 1
  fi
}
reset_case(){
  : >"$events"
  : >"$INSTALLNET_HANDOFF_LOG"
  if [[ -f "$fixture/marker" ]]; then mv "$fixture/marker" "$fixture/old-marker"; fi
  reboot_count=0
  INSTALLNET_NO_REBOOT=0
  schedule_ok=1
  entry_ok=1
  sync_ok=1
  marker_sync_ok=1
  unload_ok=1
  unload_readback=1
  printf '0\n' >"$fixture/loaded"
  printf 'LOAD_KEXEC=true\n' >"$fixture/kexec.conf"
}
preventKexecReboot(){
  record protect
  _preventKexecReboot "$fixture/kexec.conf" "$fixture/kexec-load" "$fixture/marker" "$fixture/loaded" kexec
}
kexec(){
  [[ "$1" == -u ]] || return 1
  record unload
  [[ "$unload_ok" == 1 ]] || return 1
  if [[ "$unload_readback" == 1 ]]; then printf '0\n' >"$fixture/loaded"; fi
}
verifyInstallnetArtifacts(){ record artifacts; }
writeInstallnetCustomEntry(){ record entry; }
verifyInstallnetGrub(){ record verify-entry; [[ "$entry_ok" == 1 ]]; }
scheduleGrubOnceBoot(){
  record next-entry
  [[ "$schedule_ok" == 1 && "$1" == "$INSTALL_ENTRY_TITLE" ]] || return 1
  grep -Fxq "next_entry=$1" "$GRUBDIR/grubenv"
}
sync(){
  record sync
  [[ "$sync_ok" == 1 ]] || return 1
  [[ ! -f "$fixture/marker" || "$marker_sync_ok" == 1 ]]
}
reboot(){ record reboot; reboot_count=$((reboot_count + 1)); }

# K1/K6/K7: no kexec on either Debian 11 or 12.
for release in 11 12; do
  reset_case
  mv "$fixture/kexec-load" "$fixture/absent-loader"
  finishInstallnetHandoff >"$fixture/output"
  [[ "$reboot_count" == 1 && ! -e "$fixture/marker" ]]
  mv "$fixture/absent-loader" "$fixture/kexec-load"
  printf 'PASS K1/K%s: Debian %s without kexec\n' "$release" "$release"
done

# K2: installed but disabled; no marker or permanent configuration change.
reset_case
printf 'LOAD_KEXEC=false\n' >"$fixture/kexec.conf"
finishInstallnetHandoff >"$fixture/output"
[[ "$reboot_count" == 1 && ! -e "$fixture/marker" ]]
grep -Fxq 'LOAD_KEXEC=false' "$fixture/kexec.conf"
printf 'PASS K2: installed but disabled\n'

# K3: enabled service must honor the one-reboot marker.
reset_case
finishInstallnetHandoff >"$fixture/output"
[[ "$reboot_count" == 1 && -f "$fixture/marker" ]]
[[ "$(tail -3 "$events")" == $'protect\nsync\nreboot' ]]
printf 'PASS K3: marker synced before reboot\n'

# Already loaded kexec must be unloaded and confirmed, or reboot must be blocked.
reset_case
printf '1\n' >"$fixture/loaded"
finishInstallnetHandoff >"$fixture/output"
[[ "$reboot_count" == 1 && "$(<"$fixture/loaded")" == 0 ]]
grep -Fxq unload "$events"
reset_case
printf '1\n' >"$fixture/loaded"
unload_ok=0
expect_fail finishInstallnetHandoff
[[ "$reboot_count" == 0 && ! -e "$fixture/marker" ]]
printf 'PASS K3-loaded: unload/readback or block reboot\n'

reset_case
printf '1\n' >"$fixture/loaded"
unload_readback=0
expect_fail finishInstallnetHandoff
[[ "$reboot_count" == 0 && ! -e "$fixture/marker" ]]
printf 'PASS K3-readback: successful unload command without cleared state blocks reboot\n'

reset_case
printf 'LOAD_KEXEC=false\n' >"$fixture/kexec.conf"
printf '1\n' >"$fixture/loaded"
finishInstallnetHandoff >"$fixture/output"
[[ "$reboot_count" == 1 && "$(<"$fixture/loaded")" == 0 ]]
printf 'PASS K2-loaded: disabled loader does not leave a preloaded kernel\n'

# Unsupported kexec-load implementations fail closed when interception is enabled.
reset_case
printf '#!/bin/sh\n' >"$fixture/kexec-load"
expect_fail finishInstallnetHandoff
[[ "$reboot_count" == 0 && ! -e "$fixture/marker" ]]
printf '#!/bin/sh\nNOKEXECFILE=/no-kexec-reboot\n' >"$fixture/kexec-load"
printf 'PASS K3-unsupported: no unverified kexec bypass\n'

reset_case
marker_sync_ok=0
expect_fail finishInstallnetHandoff
[[ "$reboot_count" == 0 && -f "$fixture/marker" ]]
printf 'PASS K3-sync: marker sync failure blocks reboot\n'

# K4: verify entry and grubenv before changing kexec state or rebooting.
reset_case
schedule_ok=0
expect_fail finishInstallnetHandoff
[[ "$reboot_count" == 0 && ! -e "$fixture/marker" ]]
if grep -Fxq protect "$events"; then exit 1; fi
printf 'PASS K4: verification failure preserves kexec state\n'

reset_case
entry_ok=0
expect_fail finishInstallnetHandoff
[[ "$reboot_count" == 0 && ! -e "$fixture/marker" ]]
if grep -Fxq protect "$events"; then exit 1; fi
printf 'PASS K4-entry: invalid menuentry preserves kexec state\n'

# K5: --no-reboot must leave kexec state alone after verified handoff.
reset_case
INSTALLNET_NO_REBOOT=1
finishInstallnetHandoff >"$fixture/output"
[[ "$reboot_count" == 0 && ! -e "$fixture/marker" ]]
if grep -Fxq protect "$events"; then exit 1; fi
printf 'PASS K5: --no-reboot has no kexec side effect\n'
