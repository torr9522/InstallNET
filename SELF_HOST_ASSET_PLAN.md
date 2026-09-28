# Debian 12 AMD64: fixed release assets (proposal)

Status: source-provenance verified; installer pairing and
installer-side apt consumption untested. No change to `yijianDD` is authorized
by this plan. The data in `assets/debian12-amd64.manifest.json` pins the proposed
tag `installnet-debian12-assets-v1` and the exact hashes.

| Asset / version | Size | Installation stage | Official source | Estimated benefit on slow host A |
|---|---:|---|---|---|
| Debian installer `linux`, Bookworm current fetched 2026-09-28 | 8,222,656 B | host preparation | `https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux` | Unknown; part of 56s and 5m55s preparations; direct replacement possible |
| Debian installer `initrd.gz`, same build | 40,810,276 B | host preparation | `https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz` | Potentially minutes in the slow PoC preparation; direct replacement possible |
| `linux-image-6.1.0-50-amd64` 6.1.176-1 | 70,305,560 B | d-i base-installer / target apt | `https://deb.debian.org/debian/pool/main/l/linux-signed-amd64/linux-image-6.1.0-50-amd64_6.1.176-1_amd64.deb` | At most the measured 6m05s / 19m12s apt batch, minus Release download and integration overhead; no savings until d-i integration |
| `intel-microcode` 3.20251111.1~deb12u1 | 12,848,836 B | d-i hw-detect / target apt | `https://deb.debian.org/debian/pool/non-free-firmware/i/intel-microcode/intel-microcode_3.20251111.1~deb12u1_amd64.deb` | Up to the observed 4m05s batch in one run, near zero in the other; no savings until d-i integration |

SHA256 values and signed Debian metadata chain are recorded in
`assets/debian12-amd64.sha256` and `assets/SOURCE_EVIDENCE.md`. The kernel depends
on `kmod`, `linux-base` and `initramfs-tools` (or an alternative initramfs
provider); microcode depends on `iucode-tool`. Those dependencies remain in
Debian's normal archive; do not mirror the entire dependency tree speculatively.

The earlier successful installer initrd had a different SHA256 (`034709...`).
This current set has **not** passed BIOS/UEFI, /32, multidisk or real-VPS
installation testing as a pair. `current/` is not a version-pinned fallback:
the manifest records Debian Snapshot content-addressed URLs for the identical
bytes. Only the initrd Snapshot body has been independently checked so far.

## Install path decision

1. Publish assets with immutable names/tag after confirming upload rights.
   Never overwrite v1; use v2 for changes. Release primary and Debian Snapshot
   same-hash fallback must both pass SHA256; mismatches abort or fall back, never
   silently install newer files.
2. Benchmark first full download on both hosts for each official and Release
   URL. Repeat separately if investigating cache effects. Log UTC, bytes,
   elapsed, speed, SHA256 and HTTP result. Proceed only on a meaningful,
   repeatable benefit on both hosts.
3. Host-side `linux` and `initrd.gz` can use a compact verified-download helper.
   Preserve existing handoff, disk, network, GRUB and kexec behavior. Reapply
   only the tested dependency preflight from the saved Phase 6 patch; drop its
   mirror benchmark. No normal-install benchmark.
4. For the *target* kernel and microcode, first experiment with preloading the
   exact `.deb` into the **target** apt archives before the relevant d-i apt
   transaction, then prove from installer syslog that apt actually uses the
   cache without downloading the package again. `preseed/early_command` runs
   before `/target` is available and is not by itself a working cache hook.
   Another option is a signed Debian-compatible mini repository, but GitHub
   Release asset URLs alone are not an apt repository; metadata layout,
   signature trust and d-i integration would add complexity. Injecting 83 MB
   into initrd or relying on the temporary Alpine environment is not suitable
   for the permanent fast-install path. None of these paths is validated yet.
5. If A/B benefit and apt consumption both hold, do one full A-K reinstall on
   slow host A. Do not start three consecutive reinstall runs here.

Upstream changes should only trigger `UPDATE_AVAILABLE`: check the signed
installer SHA256SUMS and signed package indexes for different checksums or
versions. A new release, test run and explicit manifest change are required
before production use; no automated v1 replacement.
