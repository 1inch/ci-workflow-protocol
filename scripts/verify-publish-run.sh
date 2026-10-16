#!/usr/bin/env bash
# Checks through the GitHub API that a PUBLISH run built its package from a release tag with the shared publish
# workflow, then downloads the package for a package admin to publish by hand.
# Usage: scripts/verify-publish-run.sh <owner/repository> <run-id> <tag>
# Needs gh, signed in with read access to the repository, jq and openssl.
set -euo pipefail

if [[ $# -ne 3 ]]; then
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
  local repository=$1 name=$2 ref sha
  ref=$(gh api "repos/$repository/git/ref/tags/$name")
  sha=$(jq -r .object.sha <<<"$ref")
  if [[ "$(jq -r .object.type <<<"$ref")" == tag ]]; then
    sha=$(gh api "repos/$repository/git/tags/$sha" | jq -r .object.sha)
  fi
  echo "$sha"
}

tag_sha=$(tag_commit "$repo" "$tag")
run=$(gh api "repos/$repo/actions/runs/$run_id")
field() {
  local name=$1
  jq -r ".$name" <<<"$run"
}

[[ "$(field event)" == workflow_dispatch ]] || fail "run $run_id was started by $(field event), not workflow_dispatch"
[[ "$(field head_sha)" == "$tag_sha" ]] || fail "run $run_id built commit $(field head_sha), not $tag ($tag_sha)"
[[ "$(field path)" == .github/workflows/publish.yml ]] || fail "run $run_id ran $(field path), not .github/workflows/publish.yml"
[[ "$(field conclusion)" == success ]] || fail "run $run_id concluded $(field conclusion), not success"

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
entries=$(find "$dir" -mindepth 1 -maxdepth 1)
[[ "$(printf '%s\n' "$entries" | grep -c .)" -eq 1 && -f "$entries" && "$entries" == *.tgz ]] ||
  fail "the npm-package artifact of run $run_id should hold one tarball, it holds: ${entries:-nothing}"
package=$entries

echo "Run $run_id built $tag ($tag_sha) with $uses ($release_sha)."
echo "Package: $package"
echo "SHA-256: $(openssl dgst -sha256 "$package" | awk '{print $NF}')"
echo "npm integrity: sha512-$(openssl dgst -sha512 -binary "$package" | openssl base64 -A)"
echo "Publish it with: npm publish $package"
