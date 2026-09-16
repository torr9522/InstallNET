#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_SCRIPT="$REPO_DIR/scripts/InstallNET.sh"
TEST_ROOT="$(mktemp -d)"
HELPERS="$TEST_ROOT/handoff-helpers.sh"
PASS_COUNT=0
FAIL_COUNT=0

trap 'rm -rf "$TEST_ROOT"' EXIT

sed -n '/^# INSTALLNET_HANDOFF_HELPERS_BEGIN$/,/^# INSTALLNET_HANDOFF_HELPERS_END$/p' "$SOURCE_SCRIPT" >"$HELPERS"
# shellcheck source=/dev/null
source "$HELPERS"
eval "$(sed -n '/^function getGrub(){/,/^}/p' "$SOURCE_SCRIPT")"

assert_success(){
  "$@"
}

assert_failure(){
  if "$@"; then
    return 1
  fi
}

run_test(){
  local name="$1"
  shift
  if ( "$@" ); then
    printf 'PASS: %s\n' "$name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    printf 'FAIL: %s\n' "$name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

new_fixture(){
  FIXTURE="$(mktemp -d "$TEST_ROOT/fixture.XXXXXX")"
  MOCK_BIN="$FIXTURE/bin"
  GRUBDIR="$FIXTURE/boot/grub"
  GRUBFILE='grub.cfg'
  GRUBVER='0'
  Type='NoBoot'
  BOOT_OPTION='auto=true hostname=debian domain=debian quiet'
  INSTALL_ENTRY_TITLE='Install OS [bookworm amd64]'
  INSTALL_ENTRY_ID='installnet-once'
  INSTALLNET_HANDOFF_LOG="$FIXTURE/installnet-handoff.log"
  INSTALLNET_MIN_KERNEL_SIZE='1'
  INSTALLNET_MIN_INITRD_SIZE='1'
  INSTALLNET_FORCE_GRUB_ONCE='1'
  INSTALLNET_NO_REBOOT='1'
  INSTALLNET_GRUB_EDITENV_COMMAND="$MOCK_BIN/grub-editenv"
  INSTALLNET_GRUB_SCRIPT_CHECK_COMMAND="$MOCK_BIN/grub-script-check"
  INSTALLNET_SOURCE_KERNEL="$FIXTURE/source-vmlinuz"
  INSTALLNET_SOURCE_INITRD="$FIXTURE/source-initrd.img"
  INSTALLNET_TARGET_KERNEL="$FIXTURE/target-vmlinuz"
  INSTALLNET_TARGET_INITRD="$FIXTURE/target-initrd.img"
  mkdir -p "$MOCK_BIN" "$GRUBDIR"
  : >"$INSTALLNET_HANDOFF_LOG"
  : >"$GRUBDIR/grubenv"
}

write_editenv_stub(){
  cat >"$MOCK_BIN/grub-editenv" <<'EOF'
#!/bin/bash
envfile="$1"
action="$2"
case "$action" in
  set)
    case "${MOCK_GRUBENV_MODE:-good}" in
      good) printf '%s\n' "$3" >"$envfile" ;;
      missing) : ;;
      wrong) printf '%s\n' 'next_entry=original-system' >"$envfile" ;;
    esac
    ;;
  list)
    cat "$envfile"
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$MOCK_BIN/grub-editenv"
}

write_syntax_stub(){
  local result="$1"
  cat >"$MOCK_BIN/grub-script-check" <<EOF
#!/bin/bash
exit $result
EOF
  chmod +x "$MOCK_BIN/grub-script-check"
}

write_artifacts(){
  printf 'installer kernel fixture\n' >"$INSTALLNET_SOURCE_KERNEL"
  printf 'installer initrd fixture\n' |gzip -c >"$INSTALLNET_SOURCE_INITRD"
  cp "$INSTALLNET_SOURCE_KERNEL" "$INSTALLNET_TARGET_KERNEL"
  cp "$INSTALLNET_SOURCE_INITRD" "$INSTALLNET_TARGET_INITRD"
}

write_grub_config(){
  cat >"$GRUBDIR/$GRUBFILE" <<EOF
set default=0
load_env
if [ "\${next_entry}" ]; then
    set default="\${next_entry}"
fi
menuentry '$INSTALL_ENTRY_TITLE' --class debian --id '$INSTALL_ENTRY_ID' {
    linux /vmlinuz $BOOT_OPTION
    initrd /initrd.img
}
EOF
}

write_inboot_grub_config(){
  cat >"$GRUBDIR/$GRUBFILE" <<EOF
set default=0
load_env
if [ "\${next_entry}" ]; then
    set default="\${next_entry}"
fi
menuentry '$INSTALL_ENTRY_TITLE' --class debian --id '$INSTALL_ENTRY_ID' {
    linux /boot/vmlinuz $BOOT_OPTION
    initrd /boot/initrd.img
}
EOF
}

test_valid_grubenv(){
  new_fixture
  write_editenv_stub
  MOCK_GRUBENV_MODE='good' scheduleGrubOnceBoot "$INSTALL_ENTRY_ID"
  grep -Fx 'next_entry=installnet-once' "$GRUBDIR/grubenv" >/dev/null
}

test_grub_path_priority(){
  new_fixture
  mkdir -p "$FIXTURE/boot/grub2"
  : >"$FIXTURE/boot/grub/grub.cfg"
  : >"$FIXTURE/boot/grub2/grub.cfg"
  [ "$(getGrub "$FIXTURE/boot")" == "$FIXTURE/boot/grub:grub.cfg:0" ]
}

test_legacy_grub_fallback(){
  new_fixture
  rm -rf "$FIXTURE/boot"
  mkdir -p "$FIXTURE/boot/special-grub"
  : >"$FIXTURE/boot/special-grub/grub.conf"
  [ "$(getGrub "$FIXTURE/boot")" == "$FIXTURE/boot/special-grub:grub.conf:1" ]
}

test_missing_next_entry(){
  new_fixture
  write_editenv_stub
  MOCK_GRUBENV_MODE='missing' assert_failure scheduleGrubOnceBoot "$INSTALL_ENTRY_ID"
}

test_wrong_next_entry(){
  new_fixture
  write_editenv_stub
  MOCK_GRUBENV_MODE='wrong' assert_failure scheduleGrubOnceBoot "$INSTALL_ENTRY_ID"
}

test_explicit_grubenv_path(){
  new_fixture
  write_editenv_stub
  mkdir -p "$FIXTURE/other-grub"
  printf '%s\n' 'next_entry=original-system' >"$FIXTURE/other-grub/grubenv"
  MOCK_GRUBENV_MODE='good' scheduleGrubOnceBoot "$INSTALL_ENTRY_ID"
  grep -Fx 'next_entry=installnet-once' "$GRUBDIR/grubenv" >/dev/null
  grep -Fx 'next_entry=original-system' "$FIXTURE/other-grub/grubenv" >/dev/null
}

test_missing_kernel(){
  new_fixture
  write_artifacts
  rm "$INSTALLNET_SOURCE_KERNEL"
  assert_failure verifyInstallerArtifacts "$INSTALLNET_SOURCE_KERNEL" "$INSTALLNET_SOURCE_INITRD" "$INSTALLNET_TARGET_KERNEL" "$INSTALLNET_TARGET_INITRD"
}

test_missing_initrd(){
  new_fixture
  write_artifacts
  rm "$INSTALLNET_SOURCE_INITRD"
  assert_failure verifyInstallerArtifacts "$INSTALLNET_SOURCE_KERNEL" "$INSTALLNET_SOURCE_INITRD" "$INSTALLNET_TARGET_KERNEL" "$INSTALLNET_TARGET_INITRD"
}

test_sha_mismatch(){
  new_fixture
  write_artifacts
  printf 'INSTALLER KERNEL FIXTURE\n' >"$INSTALLNET_TARGET_KERNEL"
  assert_failure verifyInstallerArtifacts "$INSTALLNET_SOURCE_KERNEL" "$INSTALLNET_SOURCE_INITRD" "$INSTALLNET_TARGET_KERNEL" "$INSTALLNET_TARGET_INITRD"
}

test_missing_menuentry(){
  new_fixture
  printf 'set default=0\n' >"$GRUBDIR/$GRUBFILE"
  assert_failure verifyGrubConfig
}

test_inboot_menuentry(){
  new_fixture
  Type='InBoot'
  write_inboot_grub_config
  verifyGrubConfig
}

test_syntax_failure(){
  new_fixture
  write_grub_config
  write_syntax_stub 1
  assert_failure verifyGrubSyntax
}

test_syntax_checker_missing(){
  new_fixture
  write_grub_config
  INSTALLNET_GRUB_SCRIPT_CHECK_COMMAND='none'
  verifyGrubSyntax
  grep -F '[SKIP] grub-script-check not available' "$INSTALLNET_HANDOFF_LOG" >/dev/null
}

test_real_grub_syntax(){
  command -v grub-script-check >/dev/null 2>&1 || return 0
  new_fixture
  write_grub_config
  INSTALLNET_GRUB_SCRIPT_CHECK_COMMAND='grub-script-check'
  verifyGrubSyntax
}

test_legacy_syntax_skip(){
  new_fixture
  GRUBVER='1'
  write_syntax_stub 1
  verifyGrubSyntax
  grep -F '[SKIP] grub syntax checker is only applied to GRUB2 configurations' "$INSTALLNET_HANDOFF_LOG" >/dev/null
}

test_no_reboot_preflight(){
  new_fixture
  write_editenv_stub
  write_syntax_stub 0
  write_artifacts
  write_grub_config
  cat >"$MOCK_BIN/sync" <<EOF
#!/bin/bash
printf 'sync\n' >>'$FIXTURE/calls'
EOF
  cat >"$MOCK_BIN/reboot" <<EOF
#!/bin/bash
printf 'reboot\n' >>'$FIXTURE/calls'
EOF
  chmod +x "$MOCK_BIN/sync" "$MOCK_BIN/reboot"
  PATH="$MOCK_BIN:$PATH" finishInstallerHandoff
  grep -F '[PASS] handoff preflight' "$INSTALLNET_HANDOFF_LOG" >/dev/null
  grep -F '[PASS] installer handoff verified; reboot skipped by --no-reboot' "$INSTALLNET_HANDOFF_LOG" >/dev/null
  ! grep -F 'reboot' "$FIXTURE/calls" >/dev/null
}

run_test 'valid grubenv next_entry passes' test_valid_grubenv
run_test 'standard /boot/grub path has priority' test_grub_path_priority
run_test 'legacy grub path remains available as fallback' test_legacy_grub_fallback
run_test 'successful set without next_entry fails' test_missing_next_entry
run_test 'next_entry pointing to original system fails' test_wrong_next_entry
run_test 'one-shot setter uses the selected GRUBDIR grubenv' test_explicit_grubenv_path
run_test 'missing installer kernel fails' test_missing_kernel
run_test 'missing installer initrd fails' test_missing_initrd
run_test 'SHA256 mismatch fails' test_sha_mismatch
run_test 'missing installer menuentry fails' test_missing_menuentry
run_test 'InBoot installer paths pass menuentry validation' test_inboot_menuentry
run_test 'grub syntax failure fails' test_syntax_failure
run_test 'missing syntax checker skips' test_syntax_checker_missing
run_test 'generated GRUB2 fixture passes real syntax check' test_real_grub_syntax
run_test 'legacy GRUB skips GRUB2 syntax checker' test_legacy_syntax_skip
run_test 'full preflight with no-reboot never calls reboot' test_no_reboot_preflight

printf '\nResult: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
