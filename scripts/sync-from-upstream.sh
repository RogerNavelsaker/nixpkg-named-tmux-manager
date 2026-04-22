#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
manifest_path="$repo_root/nix/package-manifest.json"
tmpdir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

replace_manifest() {
  jq "$1" "$manifest_path" > "$manifest_path.tmp"
  mv "$manifest_path.tmp" "$manifest_path"
}

require git
require jq
require nix
require rsync
require sed

homepage="$(jq -r '.meta.homepage' "$manifest_path")"
channel="$(jq -r '.source.channel // "github-head"' "$manifest_path")"
default_branch="$(jq -r '.source.defaultBranch // "main"' "$manifest_path")"
current_version="$(jq -r '.package.version' "$manifest_path")"

if [[ ! "$homepage" =~ ^https://github\.com/([^/]+)/([^/#]+) ]]; then
  echo "failed to parse GitHub owner/repo from homepage: $homepage" >&2
  exit 1
fi

owner="${BASH_REMATCH[1]}"
repo="${BASH_REMATCH[2]}"
source_repo="${1:-https://github.com/$owner/$repo.git}"

if [[ "$channel" == "github-release" ]]; then
  source_ref="${2:-$(git ls-remote --tags --refs "$source_repo" 'v*' | awk -F/ '{print $3}' | sort -V | tail -n 1)}"
else
  source_ref="${2:-$default_branch}"
fi

if [[ -z "$source_ref" ]]; then
  echo "failed to determine upstream ref" >&2
  exit 1
fi

upstream_dir="$tmpdir/upstream"
echo "syncing $source_repo @ $source_ref"
git clone --depth 1 --branch "$source_ref" "$source_repo" "$upstream_dir" >/dev/null 2>&1
rev="$(git -C "$upstream_dir" rev-parse HEAD)"

if [[ "$channel" == "github-release" ]]; then
  version="${source_ref#v}"
else
  version="$(git ls-remote --tags --refs "$source_repo" 'v*' | awk -F/ '{print $3}' | sort -V | tail -n 1)"
  version="${version#v}"
  if [[ -z "$version" ]]; then
    version="$current_version"
  fi
fi

rm -rf "$repo_root/upstream"
mkdir -p "$repo_root/upstream"
rsync -a --delete --exclude '.git' "$upstream_dir/" "$repo_root/upstream/"

replace_manifest \
  --arg version "$version" \
  --arg rev "$rev" \
  --arg branch "$source_ref" \
  --arg channel "$channel" \
  '
    .source.path = "upstream"
    | .source.channel = $channel
    | .source.rev = $rev
    | .source.version = $version
    | .package.version = $version
    | if $channel == "github-release"
      then .source.tag = $branch
      else .source.defaultBranch = $branch | del(.source.tag)
      end
    | .nix.vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  '

build_log="$tmpdir/build.log"
if nix build "$repo_root#default" >"$tmpdir/build.out" 2>"$build_log"; then
  :
else
  vendor_hash="$(sed -n 's/.*got:[[:space:]]*//p' "$build_log" | tail -n 1)"
  if [[ -z "$vendor_hash" ]]; then
    cat "$build_log" >&2
    exit 1
  fi
  replace_manifest --arg vendorHash "$vendor_hash" '.nix.vendorHash = $vendorHash'
fi

nix build "$repo_root#default" >/dev/null

echo "updated:"
echo "  source:     $source_repo"
echo "  ref:        $source_ref"
echo "  rev:        $rev"
echo "  version:    $version"
