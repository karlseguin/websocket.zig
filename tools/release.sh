#!/usr/bin/env bash
# Cut a release: bump the ONE version (build.zig.zon .version), commit, tag v<version>, push.
#   tools/release.sh 1.2.3
# The release workflow refuses a tag that doesn't match build.zig.zon.
set -euo pipefail
v="${1:?usage: tools/release.sh <semver, e.g. 1.2.3>}"
v="${v#v}"
root="$(git rev-parse --show-toplevel)"
zon="$root/build.zig.zon"
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "not semver: $v" >&2; exit 1; }
[ -z "$(git -C "$root" status --porcelain)" ] || { echo "working tree not clean" >&2; exit 1; }
sed -i.bak "s/^\( *\.version = \)\".*\",$/\1\"$v\",/" "$zon" && rm -f "$zon.bak"
grep -q "\.version = \"$v\"," "$zon" || { echo "failed to set version in $zon" >&2; exit 1; }
git -C "$root" commit -qm "release: v$v" -- "$zon"
git -C "$root" tag -a "v$v" -m "webzocket v$v"
git -C "$root" push -q origin HEAD "v$v"
echo "released v$v (CI tests and publishes it)"
