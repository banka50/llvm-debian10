#!/usr/bin/env bash
# Pins a new LLVM release: updates config/versions.env and config/sources.lock,
# then downloads the source and checks its checksum and GPG signature.
#   ./scripts/update-llvm.sh 23.1.7
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
version=${1:?usage: $0 <llvm version, e.g. 23.1.7>}
tag=llvmorg-$version
src=llvm-project-$version.src.tar.xz
base=https://github.com/llvm/llvm-project/releases/download/$tag

echo "Looking up $tag"
json=$(curl -fsSL "https://api.github.com/repos/llvm/llvm-project/releases/tags/$tag")

# Prints: <published epoch> <sha256 of tarball> <sha256 of .sig>
read -r epoch src_sha sig_sha < <(
    python3 -I -c '
import json, sys
from datetime import datetime
d = json.load(sys.stdin)
src = sys.argv[1]
digests = {a["name"]: (a.get("digest") or "").removeprefix("sha256:") for a in d["assets"]}
for name in (src, src + ".sig"):
    if not digests.get(name):
        sys.exit(f"release has no sha256 digest for {name}")
ts = datetime.strptime(d["published_at"], "%Y-%m-%dT%H:%M:%SZ")
epoch = int((ts - datetime(1970, 1, 1)).total_seconds())
print(epoch, digests[src], digests[src + ".sig"])
' "$src" <<<"$json"
)
published=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)

tmp=$(mktemp)
{
    grep '^#' "$REPO/config/sources.lock"
    echo "$src $src_sha $base/$src"
    echo "$src.sig $sig_sha $base/$src.sig"
    grep -v -e '^#' -e '^llvm-project-' -e '^$' "$REPO/config/sources.lock"
} >"$tmp"
cat "$tmp" >"$REPO/config/sources.lock"
rm -f "$tmp"

sed -i \
    -e "s/^LLVM_VERSION=.*/LLVM_VERSION=$version/" \
    -e "s/^SOURCE_DATE_EPOCH=.*/SOURCE_DATE_EPOCH=$epoch/" \
    -e "s/^# Set to the publication time of the LLVM release (.*)\.$/# Set to the publication time of the LLVM release ($published)./" \
    "$REPO/config/versions.env"

echo "Pinned LLVM $version (published $published)"
"$REPO/scripts/fetch-sources.sh"
echo
echo "Review 'git diff config/' and rebuild with ./build.sh all"
