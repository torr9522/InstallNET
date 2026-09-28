# Debian source verification (2026-09-28 UTC)

Downloaded Debian Bookworm `InRelease`, installer `SHA256SUMS`, and the `main`
and `non-free-firmware` amd64 `Packages.xz` indexes from
`https://deb.debian.org/debian/dists/bookworm/`. Local archived copies are
outside Git in `/root/installnet-debian12-audit/phase7/metadata/`.

`gpgv` validated `InRelease` with the Debian 12 archive automatic signing key
(`4CB50190207B4758A3F73A796ED0E7B82643E131`), the Debian 13 archive key,
and the Debian 12 stable release key. The signed `InRelease` SHA256 entries and
the matching downloaded metadata were:

| Metadata | SHA256 |
|---|---|
| `main/installer-amd64/current/images/SHA256SUMS` | `8e0a94d8488f7c60f5fe6723e69b450ec5d7000f592ccdb169481f4bfe863b62` |
| `main/binary-amd64/Packages.xz` | `9e0b5aabb2465b3d2e7a7fe27f9913846277833f7a2826e7767acccff5b588c5` |
| `non-free-firmware/binary-amd64/Packages.xz` | `10f5255f96b0da4e3d59efeb8bd012f922e98868d181c688b453b000d3f37352` |

The verified installer `SHA256SUMS` lists `./netboot/debian-installer/amd64/linux`
as `d8808aa4ca188560da1e6d749dcb930c87a5fd8b11ebff1f3fa6d728af35203d`
and `./netboot/debian-installer/amd64/initrd.gz` as
`cb24a28a5ba13dfb22e6e75bdd8ab997dbdee6e3ec6c1102f6c7f93044bd817d`.
The verified `main/Packages.xz` lists the 70,305,560-byte signed kernel as
`7b5597492a0a65aee61985a492e6bcc3f2cde830072a0e3b3d8c7e1b90279bd3`;
the verified `non-free-firmware/Packages.xz` lists the 12,848,836-byte Intel
microcode as `0c3227e105b4b7dd857159afe45d06ca602954d562c681430bdce866f23e1d40`.

`sha256sum -c ../InstallNET-assets/assets/debian12-amd64.sha256` in the
out-of-Git `phase7/assets` directory returned OK for all four downloaded
binaries. The Debian Snapshot initrd body also matched the pinned initrd
checksum; the other three Snapshot bodies have not been independently fetched.
Snapshot content IDs and exact official URLs are in the JSON manifest.
