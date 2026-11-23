#!/usr/bin/env bash
# Downloads every input listed in config/sources.lock into sources/ and checks
# its SHA-256. Files that are already present are only re-verified.
# The LLVM source tarball is additionally checked against the LLVM release
# signing keys in keys/ (if gpg is installed).
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCES_DIR=$REPO/sources
ARCH=${ARCH:-$(uname -m)}
# shellcheck source=../config/versions.env
source "$REPO/config/versions.env"

mkdir -p "$SOURCES_DIR"
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

while read -r name sha url; do
    case "$name" in '' | '#'*) continue ;; esac
    # Only fetch the CMake binary for the architecture being built.
    case "$name" in
        *-linux-x86_64.* | *-linux-aarch64.*) [[ $name == *-linux-$ARCH.* ]] || continue ;;
    esac
    f=$SOURCES_DIR/$name
    if [[ -f $f && $(sha256_of "$f") == "$sha" ]]; then
        echo "ok       $name"
        continue
    fi
    echo "fetch    $name"
    curl -fL --retry 5 --retry-delay 5 --silent --show-error -o "$f.part" "$url"
    got=$(sha256_of "$f.part")
    if [[ $got != "$sha" ]]; then
        rm -f "$f.part"
        echo "error: sha256 mismatch for $name" >&2
        echo "  expected $sha" >&2
        echo "  got      $got" >&2
        exit 1
    fi
    mv "$f.part" "$f"
    echo "ok       $name"
done <"$REPO/config/sources.lock"

tarball=$SOURCES_DIR/llvm-project-$LLVM_VERSION.src.tar.xz
[[ -f $tarball ]] || { echo "error: $tarball is not listed in config/sources.lock" >&2; exit 1; }

if command -v gpg >/dev/null 2>&1; then
    gnupghome=$(mktemp -d)
    trap 'rm -rf "$gnupghome"' EXIT
    gpg --homedir "$gnupghome" --batch --quiet --import "$REPO/keys/llvm-release-keys.asc" 2>/dev/null
    if status=$(gpg --homedir "$gnupghome" --batch --status-fd 1 --verify "$tarball.sig" "$tarball" 2>/dev/null); then
        echo "gpg      $(basename "$tarball"): good signature, key $(awk '$2 == "VALIDSIG" {print $3}' <<<"$status")"
    else
        echo "error: bad GPG signature on $tarball" >&2
        exit 1
    fi
else
    echo "note: gpg not installed, signature not checked (sha256 matched the lock file)"
fi
