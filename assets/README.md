# Debian 12 AMD64 assets

The JSON manifest and SHA256 list describe frozen Debian-origin assets for the
`installnet-debian12-assets-v1` GitHub Release. Large binaries are not stored
in Git.

These files are provenance-verified but the combination has **not** been
validated in a new installation. The published `yijianDD` installer does not
reference this release. A future script revision must use the same expected
SHA256 for both the Release and the version-pinned Debian Snapshot fallback.
Never silently substitute the changing `current/` installer artifacts.

The release only provides files. Debian Installer still downloads target
kernel and microcode packages from its apt mirror until an installer-side
integration is separately tested.
