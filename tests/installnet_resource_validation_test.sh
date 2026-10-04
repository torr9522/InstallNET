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
truncate -s 2097152 "$fixture/source/vmlinuz"
head -c 2097152 /dev/urandom |gzip >"$fixture/source/initrd.img"

MOCK_KERNEL_ARCH=arm64
file() {
  case "$MOCK_KERNEL_ARCH" in
    arm64) printf '%s\n' 'Linux kernel ARM64 boot executable Image, little-endian, 4K pages' ;;
    amd64) printf '%s\n' 'Linux kernel x86 boot executable bzImage, version 6.1.0' ;;
    *) printf '%s\n' 'data' ;;
  esac
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

copy_artifacts
verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" arm64 >"$fixture/output"
printf 'PASS: correct ARM64 installer kernel accepted\n'

MOCK_KERNEL_ARCH=amd64
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
MOCK_KERNEL_ARCH=amd64
expect_fail verifyInstallnetArtifacts \
  "$fixture/source/vmlinuz" "$fixture/source/initrd.img" \
  "$fixture/target/vmlinuz" "$fixture/target/initrd.img" arm64
grep -Fq 'installer kernel architecture mismatch' "$fixture/output"
printf 'PASS: wrong-architecture kernel rejected\n'
