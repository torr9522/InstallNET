#!/bin/bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

# Source helpers only: running the main script would modify the host bootloader.
source <(awk '
  /^function getGrub\(\)\{/ { copy = 1 }
  copy && /^if \[\[ "\$loaderMode" == "0" \]\]; then$/ { exit }
  copy { print }
' "$script")

GRUBDIR="$fixture/boot/grub"
GRUBFILE=grub.cfg
GRUBVER=0
GRUB_KERNEL_PATH=/boot/vmlinuz
GRUB_INITRD_PATH=/boot/initrd.img
INSTALL_ENTRY_TITLE='Install OS [bookworm amd64]'
INSTALLNET_HANDOFF_LOG="$fixture/handoff.log"
INSTALLNET_NO_REBOOT=1
BOOT_OPTION='auto=true hostname=debian domain=debian quiet'
mkdir -p "$GRUBDIR" "$fixture/source" "$fixture/target"

cat >"$GRUBDIR/grub.cfg" <<'EOF'
load_env
menuentry 'Original OS' {
    linux /boot/old-kernel root=/dev/vda1
    initrd /boot/old-initrd
}
if [ -f ${config_directory}/custom.cfg ]; then
    source ${config_directory}/custom.cfg
fi
EOF
printf "menuentry 'Existing custom entry' { true; }\n" >"$GRUBDIR/custom.cfg"
printf 'next_entry=Original OS\n' >"$GRUBDIR/grubenv"
truncate -s 2097152 "$fixture/source/vmlinuz"
head -c 2097152 /dev/urandom |gzip >"$fixture/source/initrd.img"
cp "$fixture/source/vmlinuz" "$fixture/target/vmlinuz"
cp "$fixture/source/initrd.img" "$fixture/target/initrd.img"

MOCK_SCHEDULE=good
MOCK_CHECK=good
MOCK_READ=good
MOCK_REBOOT=0
commandExists(){ [[ "$1" != grub2-script-check && "$1" != absent-tool ]]; }
update-grub(){ return 0; }
grub-reboot(){
  case "$MOCK_SCHEDULE" in
    fail) return 1 ;;
    missing) : >"$GRUBDIR/grubenv" ;;
    wrong) printf 'next_entry=Original OS\n' >"$GRUBDIR/grubenv" ;;
    *) printf 'next_entry=%s\n' "$1" >"$GRUBDIR/grubenv" ;;
  esac
}
grub-editenv(){ [[ "$MOCK_READ" == good ]] && cat "$1"; }
grub-script-check(){ [[ "$MOCK_CHECK" == good ]] && /usr/bin/grub-script-check "$1"; }
sync(){ :; }
reboot(){ MOCK_REBOOT=$((MOCK_REBOOT + 1)); }

expect_fail(){
  if "$@" >"$fixture/output" 2>&1; then
    echo "FAIL: unexpectedly passed: $*" >&2
    exit 1
  fi
}

[[ "$(getGrub "$fixture/boot")" == "$GRUBDIR:grub.cfg:0" ]]
echo 'PASS: prefer real GRUB2 configuration'
prepareInstallnetGrub >"$fixture/output"
echo 'PASS: GRUB custom.cfg hook checked'
cp "$GRUBDIR/grub.cfg" "$fixture/grub.cfg.backup"
sed -i '/source .*custom.cfg/d' "$GRUBDIR/grub.cfg"
expect_fail prepareInstallnetGrub
cp "$fixture/grub.cfg.backup" "$GRUBDIR/grub.cfg"
echo 'PASS: missing GRUB custom.cfg hook blocked'
verifyInstallnetArtifacts "$fixture/source/vmlinuz" "$fixture/source/initrd.img" "$fixture/target/vmlinuz" "$fixture/target/initrd.img" >"$fixture/output"
echo 'PASS: installer files match'
expect_fail verifyInstallnetArtifacts "$fixture/missing" "$fixture/source/initrd.img" "$fixture/target/vmlinuz" "$fixture/target/initrd.img"
expect_fail verifyInstallnetArtifacts "$fixture/source/vmlinuz" "$fixture/missing" "$fixture/target/vmlinuz" "$fixture/target/initrd.img"
printf 'x' |dd of="$fixture/target/vmlinuz" bs=1 conv=notrunc status=none
expect_fail verifyInstallnetArtifacts "$fixture/source/vmlinuz" "$fixture/source/initrd.img" "$fixture/target/vmlinuz" "$fixture/target/initrd.img"
printf 'bad gzip\n' >"$fixture/invalid-initrd.img"
expect_fail verifyInstallnetArtifacts "$fixture/source/vmlinuz" "$fixture/invalid-initrd.img" "$fixture/target/vmlinuz" "$fixture/target/initrd.img"
echo 'PASS: missing or different installer files blocked'

chmod 600 "$GRUBDIR/custom.cfg"
writeInstallnetCustomEntry >"$fixture/output"
writeInstallnetCustomEntry >"$fixture/output"
[[ "$(grep -Fc "menuentry '$INSTALL_ENTRY_TITLE'" "$GRUBDIR/custom.cfg")" == 1 ]]
[[ "$(stat -c %a "$GRUBDIR/custom.cfg")" == 600 ]]
grep -Fq 'Existing custom entry' "$GRUBDIR/custom.cfg"
verifyInstallnetGrub >"$fixture/output"
echo 'PASS: custom entry preserved, installed once and syntax checked'
MOCK_CHECK=fail
expect_fail verifyInstallnetGrub
expect_fail finishInstallnetHandoff
[[ "$MOCK_REBOOT" == 0 ]]
MOCK_CHECK=good
cp "$GRUBDIR/custom.cfg" "$fixture/custom.backup"
printf "menuentry 'Original OS' { true; }\n" >"$GRUBDIR/custom.cfg"
expect_fail verifyInstallnetGrub
cp "$fixture/custom.backup" "$GRUBDIR/custom.cfg"
echo 'PASS: invalid GRUB syntax or missing entry blocked'

MOCK_SCHEDULE=missing
expect_fail scheduleVerifiedInstallnetBoot
MOCK_SCHEDULE=wrong
expect_fail scheduleVerifiedInstallnetBoot
expect_fail finishInstallnetHandoff
[[ "$MOCK_REBOOT" == 0 ]]
MOCK_SCHEDULE=fail
expect_fail scheduleVerifiedInstallnetBoot
MOCK_SCHEDULE=good
MOCK_READ=fail
expect_fail scheduleVerifiedInstallnetBoot
MOCK_READ=good
scheduleVerifiedInstallnetBoot >"$fixture/output"
grep -Fxq "next_entry=$INSTALL_ENTRY_TITLE" "$GRUBDIR/grubenv"
echo 'PASS: one-shot command and grubenv readback checked'

commandExists(){ [[ "$1" != grub-script-check && "$1" != grub2-script-check ]]; }
verifyInstallnetGrub >"$fixture/output"
grep -Fq '[SKIP] GRUB syntax checker unavailable' "$INSTALLNET_HANDOFF_LOG"
echo 'PASS: missing GRUB syntax checker is skipped'
commandExists(){ [[ "$1" != grub2-script-check ]]; }

verifyInstallnetArtifacts(){ :; }
finishInstallnetHandoff >"$fixture/output"
[[ "$MOCK_REBOOT" == 0 ]]
grep -Fq '[PASS] --no-reboot: reboot skipped' "$INSTALLNET_HANDOFF_LOG"
echo 'PASS: full handoff preflight with --no-reboot does not reboot'
