#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

# Source only the installer handoff helpers, never the destructive main body.
source <(awk '
  /^function getGrub\(\)\{/ { copy = 1 }
  copy && /^if \[\[ "\$loaderMode" == "0" \]\]; then$/ { exit }
  copy { print }
' "$script")

INSTALLNET_HANDOFF_LOG="$fixture/handoff.log"
mkdir -p "$fixture/source" "$fixture/target" "$fixture/backing"
head -c 2097152 /dev/urandom |gzip >"$fixture/source/initrd.img"

make_kernel() {
  local architecture=$1 target=$2
  : >"$target"
  truncate -s 2097152 "$target"
  case "$architecture" in
    arm64) printf ARMd |dd of="$target" bs=1 seek=56 conv=notrunc status=none ;;
    amd64) printf HdrS |dd of="$target" bs=1 seek=514 conv=notrunc status=none ;;
  esac
}

make_pe_kernel() {
  local architecture=$1 target=$2 machine
  : >"$target"
  truncate -s 2097152 "$target"
  case "$architecture" in
    arm64) machine='\x64\xaa' ;;
    amd64) machine='\x64\x86' ;;
  esac
  printf 'MZ' |dd of="$target" bs=1 conv=notrunc status=none
  printf '\x40\x00\x00\x00' |dd of="$target" bs=1 seek=60 conv=notrunc status=none
  printf 'PE\x00\x00' |dd of="$target" bs=1 seek=64 conv=notrunc status=none
  printf '%b' "$machine" |dd of="$target" bs=1 seek=68 conv=notrunc status=none
}

expect_fail() {
  if "$@" >"$fixture/output" 2>&1; then
    printf 'FAIL: unexpectedly passed: %s\n' "$*" >&2
    exit 1
  fi
}

copy_artifacts() {
  cp "$fixture/source/vmlinuz" "$fixture/target/vmlinuz"
  cp "$fixture/source/initrd.img" "$fixture/target/initrd.img"
}

make_kernel arm64 "$fixture/source/vmlinuz"
copy_artifacts
verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" arm64 >"$fixture/output"
printf 'PASS: correct ARM64 installer kernel accepted\n'

make_pe_kernel arm64 "$fixture/source/vmlinuz"
copy_artifacts
verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" arm64 >"$fixture/output"
printf 'PASS: ARM64 PE/COFF installer kernel accepted\n'

make_pe_kernel amd64 "$fixture/source/vmlinuz"
copy_artifacts
expect_fail verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" arm64
grep -Fq 'installer kernel architecture mismatch' "$fixture/output"
printf 'PASS: wrong-architecture PE/COFF installer kernel rejected\n'

make_kernel amd64 "$fixture/source/vmlinuz"
copy_artifacts
verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" amd64 >"$fixture/output"
printf 'PASS: correct AMD64 installer kernel accepted\n'

cp "$fixture/source/vmlinuz" "$fixture/backing/vmlinuz"
cp "$fixture/source/initrd.img" "$fixture/backing/initrd.img"
ln -sf ../backing/vmlinuz "$fixture/target/vmlinuz"
ln -sf ../backing/initrd.img "$fixture/target/initrd.img"
verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" amd64 >"$fixture/output"
printf 'PASS: symlinked installer targets are measured by content\n'

rm "$fixture/target/vmlinuz" "$fixture/target/initrd.img"
copy_artifacts
truncate -s 1048576 "$fixture/target/vmlinuz"
expect_fail verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" amd64
grep -Fq 'installer kernel size mismatch' "$fixture/output"
printf 'PASS: truncated kernel rejected\n'

copy_artifacts
printf x |dd of="$fixture/target/vmlinuz" bs=1 conv=notrunc status=none
expect_fail verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" amd64
grep -Fq 'installer kernel SHA256 mismatch' "$fixture/output"
printf 'PASS: same-size modified kernel rejected\n'

copy_artifacts
expect_fail verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" arm64
grep -Fq 'installer kernel architecture mismatch' "$fixture/output"
printf 'PASS: wrong-architecture kernel rejected\n'
