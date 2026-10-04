#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/InstallNET.sh"

source <(awk '
  /^function resolveDistributionCodename\(\)\{/ { copy = 1 }
  copy { print }
  copy && /^}/ { exit }
' "$script")

assert_release() {
  local release=$1 requested=$2 expected=$3 actual
  actual=$(resolveDistributionCodename "$release" "$requested")
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %s %s -> %s, got %s\n' "$release" "$requested" "$expected" "$actual" >&2
    exit 1
  }
}

assert_release Debian 11 bullseye
assert_release Debian 12 bookworm
assert_release Debian 13 trixie
assert_release Debian Trixie trixie
assert_release Ubuntu 20.04 focal
assert_release Ubuntu 22.04 jammy
assert_release Ubuntu 24.04 noble
assert_release Ubuntu Noble noble

printf 'PASS: Debian and Ubuntu release mappings\n'
