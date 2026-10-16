#!/usr/bin/env bash
# Runs scripts/verify-publish-run.sh against fixed GitHub API answers, with gh stubbed.
# Needs bash, jq and openssl.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
script=$root/scripts/verify-publish-run.sh
sim=$(mktemp -d)
trap 'rm -rf "$sim"' EXIT
mkdir -p "$sim/bin" "$sim/tmp" "$sim/package"
printf '{"name":"@1inch/aqua","version":"1.0.1"}\n' > "$sim/package/package.json"

tag_sha=1111111111111111111111111111111111111111
release_sha=2222222222222222222222222222222222222222
shared=1inch/ci-workflow-protocol/.github/workflows/publish.yml@v2.2.0

cat > "$sim/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "run download" ]; then
  while [ $# -gt 0 ]; do
    [ "$1" = --dir ] && dir=$2
    shift
  done
  tar -czf "$dir/1inch-aqua-1.0.1.tgz" -C "$SIM" package
  if [ "$SIM_EXTRA_MEMBER" = 1 ]; then
    echo stray > "$dir/stray.txt"
  fi
  exit 0
fi
[ "$1" = api ] || exit 1
shift
while [ "$1" = -H ]; do
  shift 2
done
case "$1" in
  repos/1inch/aqua/git/ref/tags/v1.0.1) printf '{"object":{"type":"commit","sha":"%s"}}\n' "$SIM_TAG_SHA" ;;
  repos/1inch/ci-workflow-protocol/git/ref/tags/v2.2.0) echo '{"object":{"type":"tag","sha":"3333333333333333333333333333333333333333"}}' ;;
  repos/1inch/ci-workflow-protocol/git/tags/3333333333333333333333333333333333333333) printf '{"object":{"type":"commit","sha":"%s"}}\n' "$SIM_RELEASE_SHA" ;;
  "repos/1inch/aqua/contents/.github/workflows/publish.yml?ref=$SIM_TAG_SHA") cat "$SIM/caller.yml" ;;
  repos/1inch/aqua/actions/runs/123) cat "$SIM/run.json" ;;
  *) echo "gh: no answer for $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$sim/bin/gh"

failures=0
last_out=
extra_member=0

caller() {
  local uses=$1
  printf 'jobs:\n  publish-npmjs:\n    uses: %s\n' "$uses" > "$sim/caller.yml"
  return 0
}

# run <event> <head_sha> <path> <conclusion> <referenced workflow path> <referenced workflow sha>
run() {
  local event=$1 head_sha=$2 path=$3 conclusion=$4 ref_path=$5 ref_sha=$6
  jq -n --arg event "$event" --arg head_sha "$head_sha" --arg path "$path" --arg conclusion "$conclusion" \
    --arg ref_path "$ref_path" --arg ref_sha "$ref_sha" \
    '{event: $event, head_sha: $head_sha, path: $path, status: "completed", conclusion: $conclusion,
      referenced_workflows: [{path: $ref_path, sha: $ref_sha, ref: "refs/tags/v2.2.0"}]}' > "$sim/run.json"
  return 0
}

# check <title> <"ok" or text the error must contain>
check() {
  local title=$1 expected=$2 status=0
  last_out=$(PATH="$sim/bin:$PATH" TMPDIR="$sim/tmp" SIM="$sim" SIM_TAG_SHA=$tag_sha SIM_RELEASE_SHA=$release_sha SIM_EXTRA_MEMBER=$extra_member \
    bash "$script" 1inch/aqua 123 v1.0.1 2>&1) || status=$?
  if [[ ( "$expected" == ok && "$status" -eq 0 ) || ( "$expected" != ok && "$status" -ne 0 && "$last_out" == *"$expected"* ) ]]; then
    echo "ok   $title"
  else
    echo "FAIL $title: expected \"$expected\", got exit $status: $last_out"
    failures=$((failures + 1))
  fi
  return 0
}

caller "$shared"
run workflow_dispatch "$tag_sha" .github/workflows/publish.yml success "$shared" "$release_sha"
check "a pack-only run on the release tag" ok
package=$(sed -n 's/^Package: //p' <<<"$last_out")
integrity="npm integrity: sha512-$(openssl dgst -sha512 -binary "$package" 2>/dev/null | openssl base64 -A)"
if [[ -n "$package" && "$last_out" == *"$integrity"* ]]; then
  echo "ok   the printed integrity is the downloaded package's"
else
  echo "FAIL the printed integrity is the downloaded package's: $last_out"
  failures=$((failures + 1))
fi

extra_member=1
check "an artifact with a second file" "should hold one tarball"
extra_member=0

run push "$tag_sha" .github/workflows/publish.yml success "$shared" "$release_sha"
check "a run not started by workflow_dispatch" "not workflow_dispatch"
run workflow_dispatch 4444444444444444444444444444444444444444 .github/workflows/publish.yml success "$shared" "$release_sha"
check "a run on another commit than the tag's" "not v1.0.1"
run workflow_dispatch "$tag_sha" .github/workflows/ci.yml success "$shared" "$release_sha"
check "a run of another workflow file" "not .github/workflows/publish.yml"
run workflow_dispatch "$tag_sha" .github/workflows/publish.yml failure "$shared" "$release_sha"
check "a failed run" "not success"
run workflow_dispatch "$tag_sha" .github/workflows/publish.yml success "$shared" 5555555555555555555555555555555555555555
check "a run that called the shared workflow at another commit" "did not call"
run workflow_dispatch "$tag_sha" .github/workflows/publish.yml success "attacker/fork/.github/workflows/publish.yml@v2.2.0" "$release_sha"
check "a run that called another workflow" "did not call"
caller "attacker/fork/.github/workflows/publish.yml@v2.2.0"
run workflow_dispatch "$tag_sha" .github/workflows/publish.yml success "$shared" "$release_sha"
check "a tag whose publish.yml does not call the shared workflow" "does not call the shared publish workflow"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "All scenarios passed"
