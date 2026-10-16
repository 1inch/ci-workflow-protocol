#!/usr/bin/env bash
# Checks through the GitHub API that a PUBLISH run built its package from a release tag with the shared publish
# workflow, then downloads the package for a package admin to publish by hand.
# Usage: scripts/verify-publish-run.sh <owner/repository> <run-id> <tag>
# Needs gh, signed in with read access to the repository, jq and openssl.
set -euo pipefail

if [ $# -ne 3 ]; then
  echo "usage: $0 <owner/repository> <run-id> <tag>" >&2
  exit 2
fi
repo=$1 run_id=$2 tag=$3

fail() {
  echo "error: $*" >&2
  exit 1
}

# Prints the commit a tag points to, through the tag object of an annotated tag.
tag_commit() {
  local ref sha
  ref=$(gh api "repos/$1/git/ref/tags/$2")
  sha=$(jq -r .object.sha <<<"$ref")
  if [ "$(jq -r .object.type <<<"$ref")" = tag ]; then
    sha=$(gh api "repos/$1/git/tags/$sha" | jq -r .object.sha)
  fi
  echo "$sha"
}

tag_sha=$(tag_commit "$repo" "$tag")
run=$(gh api "repos/$repo/actions/runs/$run_id")
field() {
  jq -r ".$1" <<<"$run"
}

[ "$(field event)" = workflow_dispatch ] || fail "run $run_id was started by $(field event), not workflow_dispatch"
[ "$(field head_sha)" = "$tag_sha" ] || fail "run $run_id built commit $(field head_sha), not $tag ($tag_sha)"
[ "$(field path)" = .github/workflows/publish.yml ] || fail "run $run_id ran $(field path), not .github/workflows/publish.yml"
[ "$(field conclusion)" = success ] || fail "run $run_id concluded $(field conclusion), not success"

# The shared workflow release that publish.yml names at the tag's commit, pinned to that release's commit.
caller=$(gh api -H 'Accept: application/vnd.github.raw+json' "repos/$repo/contents/.github/workflows/publish.yml?ref=$tag_sha")
uses=$(grep -m 1 -oE '1inch/ci-workflow-protocol/\.github/workflows/publish\.yml@[^[:space:]]+' <<<"$caller") ||
  fail ".github/workflows/publish.yml at $tag does not call the shared publish workflow"
release=${uses#*@}
if [[ "$release" =~ ^[0-9a-f]{40}$ ]]; then
  release_sha=$release
else
  release_sha=$(tag_commit 1inch/ci-workflow-protocol "$release")
fi
jq -e --arg path "$uses" --arg sha "$release_sha" 'any(.referenced_workflows[]?; .path == $path and .sha == $sha)' <<<"$run" >/dev/null ||
  fail "run $run_id did not call $uses at $release_sha"

dir=$(mktemp -d)
gh run download "$run_id" --repo "$repo" --name npm-package --dir "$dir"
packages=$(find "$dir" -maxdepth 1 -type f -name '*.tgz')
[ "$(printf '%s\n' "$packages" | grep -c .)" -eq 1 ] || fail "the npm-package artifact of run $run_id holds ${packages:-no tarball}"

echo "Run $run_id built $tag ($tag_sha) with $uses ($release_sha)."
echo "Package: $packages"
echo "SHA-256: $(openssl dgst -sha256 "$packages" | awk '{print $NF}')"
echo "npm integrity: sha512-$(openssl dgst -sha512 -binary "$packages" | openssl base64 -A)"
echo "Publish it with: npm publish $packages"
