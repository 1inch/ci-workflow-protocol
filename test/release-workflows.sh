#!/usr/bin/env bash
# Runs the `run` steps of tag.yml, release.yml and publish.yml against fixed scenarios, with gh and npm stubbed.
# Needs bash, jq and ruby. WORKFLOWS points at another copy of .github/workflows.
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
workflows=${WORKFLOWS:-$root/.github/workflows}
sim=$(mktemp -d)
trap 'rm -rf "$sim"' EXIT
mkdir -p "$sim/bin"

cat > "$sim/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$SIM_LOG"
[ "$1" = api ] || exit 0
path=$2
shift 2
jq_expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$path" in
  *actions/runs*)
    head_sha=${path#*head_sha=}
    if [ "$head_sha" = "$path" ]; then
      head_sha=
    else
      head_sha=${head_sha%%&*}
    fi
    jq --arg head_sha "$head_sha" '{"workflow_runs":[.workflow_runs[] | select($head_sha == "" or .head_sha == $head_sha)]}' "$SIM_RUNS" |
      jq -r "${jq_expr:-.}"
    ;;
  */git/refs)
    if [ "$SIM_TAG_EXISTS" = 1 ]; then
      echo "gh: Reference already exists (HTTP 422)" >&2
      exit 1
    fi
    ;;
esac
EOF
cat > "$sim/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$SIM_LOG"
EOF
cat > "$sim/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$SIM_LOG"
if [ "$1" = merge-base ] && [ "$SIM_ON_BRANCH" != 1 ]; then
  exit 1
fi
EOF
cat > "$sim/bin/yarn" <<'EOF'
#!/usr/bin/env bash
echo "yarn $*" >> "$SIM_LOG"
EOF
chmod +x "$sim/bin/gh" "$sim/bin/npm" "$sim/bin/git" "$sim/bin/yarn"

failures=0
tag_exists=0
on_branch=1
dry_run=false

ci_run() {
  local result=$1 event=${2:-push} sha=${3:-abc1234}
  case "$1" in
    none) echo '{"workflow_runs":[]}' ;;
    in_progress) printf '{"workflow_runs":[{"name":"CI","event":"%s","head_sha":"%s","status":"in_progress","conclusion":null}]}\n' "$event" "$sha" ;;
    *) printf '{"workflow_runs":[{"name":"CI","event":"%s","head_sha":"%s","status":"completed","conclusion":"%s"}]}\n' "$event" "$sha" "$result" ;;
  esac > "$sim/runs.json"
}

step_script() {
  ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0])["jobs"].values.flat_map { |job| job["steps"] || [] }
    step = steps.find { |s| s["name"] == ARGV[1] } or abort
    print step["run"]
  ' "$1" "$2"
}

# Prints "ok", or the name of the first step that fails.
run_steps() {
  local workflow=$1 version=$2 ref=$3
  shift 3
  local wd
  wd=$(mktemp -d "$sim/wd.XXXX")
  printf '{"name":"@1inch/solidity-utils","version":"%s"}\n' "$version" > "$wd/package.json"
  mkdir -p "$wd/package/package"
  cp "$wd/package.json" "$wd/package/package/package.json"
  tar -czf "$wd/package/package.tgz" -C "$wd/package" package
  rm -r "$wd/package/package"
  : > "$wd/env"
  : > "$sim/calls"
  (
    export PATH="$sim/bin:$PATH" SIM_LOG="$sim/calls" SIM_RUNS="$sim/runs.json" SIM_TAG_EXISTS=$tag_exists SIM_ON_BRANCH=$on_branch DRY_RUN=$dry_run
    export GITHUB_REPOSITORY=1inch/solidity-utils GITHUB_SHA=abc1234 GH_TOKEN=stub TAG_PREFIX=v
    export GITHUB_REF=$ref GITHUB_REF_NAME=${ref#refs/*/} GITHUB_ENV="$wd/env" GITHUB_OUTPUT="$wd/output"
    for step in "$@"; do
      script=$(step_script "$workflows/$workflow" "$step") || { echo "missing step: $step"; exit 0; }
      set -a
      . "$GITHUB_ENV"
      set +a
      if ! (cd "$wd" && bash -e -c "$script") > "$wd/log" 2>&1; then
        echo "$step"
        exit 0
      fi
    done
    echo ok
  )
}

# check <title> <"ok" or the step that must fail> <regex for the tag and publish calls, or "-" for none> <workflow> <version> <ref> <steps...>
check() {
  local title=$1 expected=$2 calls=$3
  shift 3
  local got recorded calls_match=false
  got=$(run_steps "$@")
  recorded=$(grep -E '^(gh api [^ ]*/git/refs|npm )' "$sim/calls" | tr '\n' ' ')
  if [ "$calls" = - ]; then
    [ -z "$recorded" ] && calls_match=true
  elif [[ "$recorded" =~ $calls ]]; then
    calls_match=true
  fi
  if [ "$got" = "$expected" ] && $calls_match; then
    echo "ok   $title"
  else
    echo "FAIL $title: expected \"$expected\" and calls /$calls/, got \"$got\" and calls \"$recorded\""
    failures=$((failures + 1))
  fi
}

environment=$(ruby -ryaml -e 'print YAML.load_file(ARGV[0])["jobs"]["npm"]["environment"].to_s' "$workflows/publish.yml")
if [ "$environment" = npm ]; then
  echo "ok   PUBLISH runs in the npm environment"
else
  echo "FAIL PUBLISH runs in the npm environment: got \"$environment\""
  failures=$((failures + 1))
fi

npm_has_install=$(ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0])["jobs"]["npm"]["steps"]
  found = steps.any? { |step| step["name"].to_s.match?(/install/i) || step["run"].to_s.match?(/\b(yarn install|npm (ci|install))\b/) }
  print found
' "$workflows/publish.yml")
if [ "$npm_has_install" = false ]; then
  echo "ok   PUBLISH npm job has no install step"
else
  echo "FAIL PUBLISH npm job has an install step"
  failures=$((failures + 1))
fi

npm_actions_pinned=$(ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0])["jobs"]["npm"]["steps"]
  found = steps.select { |step| step["uses"] }.all? { |step| step["uses"].match?(/@[0-9a-f]{40}$/) }
  print found
' "$workflows/publish.yml")
if [ "$npm_actions_pinned" = true ]; then
  echo "ok   PUBLISH npm job actions are SHA-pinned"
else
  echo "FAIL PUBLISH npm job has a mutable action reference"
  failures=$((failures + 1))
fi

tag_steps=("Check the release branch" "Check CI on the branch head" "Tag the version in package.json")
tagged='git/refs -f ref=refs/tags/v7\.0\.1 '

ci_run success
check "TAG from release/7.0.1 after push CI passed" ok "$tagged" tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
ci_run success workflow_dispatch
check "TAG from release/7.0.1 after dispatched CI passed" ok "$tagged" tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
ci_run success pull_request
check "TAG ignores pull request CI" "Check CI on the branch head" - tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
ci_run success push other123
check "TAG ignores CI from another commit" "Check CI on the branch head" - tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
check "TAG from main" "Check the release branch" - tag.yml 7.0.1 refs/heads/main "${tag_steps[@]}"
check "TAG from release/7.0.2 while package.json says 7.0.1" "Check the release branch" - tag.yml 7.0.1 refs/heads/release/7.0.2 "${tag_steps[@]}"
ci_run failure
check "TAG after CI failed" "Check CI on the branch head" - tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
ci_run in_progress
check "TAG while CI still runs" "Check CI on the branch head" - tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
ci_run none
check "TAG without a CI run for the commit" "Check CI on the branch head" - tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
ci_run success
tag_exists=1
check "TAG when v7.0.1 already exists" "Tag the version in package.json" "$tagged" tag.yml 7.0.1 refs/heads/release/7.0.1 "${tag_steps[@]}"
tag_exists=0

check "CREATE_RELEASE from v7.0.1" ok - release.yml 7.0.1 refs/tags/v7.0.1 "Find the release tag"
check "CREATE_RELEASE from release/7.0.1" "Find the release tag" - release.yml 7.0.1 refs/heads/release/7.0.1 "Find the release tag"
check "CREATE_RELEASE from v7.0.0 while package.json says 7.0.1" "Find the release tag" - release.yml 7.0.1 refs/tags/v7.0.0 "Find the release tag"

publish_build_steps=("Check the release tag" "Check the release branch" "Check CI on the tag commit")
ci_run success
on_branch=1
check "PUBLISH build from tested release tag" ok - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
on_branch=0
check "PUBLISH rejects tag off release branch" "Check the release branch" - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
on_branch=1
ci_run failure
check "PUBLISH rejects tag without passed CI" "Check CI on the tag commit" - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
ci_run success workflow_dispatch
check "PUBLISH accepts dispatched CI" ok - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
check "PUBLISH from v7.0.1" ok '^npm publish package/package\.tgz $' publish.yml 7.0.1 refs/tags/v7.0.1 "Publish"
check "PUBLISH a pre-release from v7.1.0-rc.1" ok '^npm publish package/package\.tgz --tag next $' publish.yml 7.1.0-rc.1 refs/tags/v7.1.0-rc.1 "Publish"
dry_run=true
check "PUBLISH dry-run" ok '^npm publish package/package\.tgz --dry-run $' publish.yml 7.0.1 refs/tags/v7.0.1 "Publish"
dry_run=false
check "PUBLISH from main" "Check the release tag" - publish.yml 7.0.1 refs/heads/main "Check the release tag" "Publish"

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "All scenarios passed"
