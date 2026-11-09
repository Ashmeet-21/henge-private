Copies of two of Husk's source tarballs, byte-identical to the GitHub release files Husk's
scripts/sources.sh names (checked against the sha256 digests GitHub records for those assets).
GitHub's release downloads answered 504 to the build runners for hours on 2026-11-08; the
build copies these into husk/third_party/sources so fetch_sources.sh skips them.
