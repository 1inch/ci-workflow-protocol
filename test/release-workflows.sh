#!/usr/bin/env bash
# Runs the `run` steps of tag.yml, release.yml and publish.yml, and publish.yml's jobs end to end, against fixed
# scenarios, with gh, git, npm and yarn stubbed.
# Needs bash, jq, ruby and openssl. WORKFLOWS points at another copy of .github/workflows.
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
if [ "$1" = --version ]; then
  echo "$SIM_NPM_VERSION"
fi
if [ "$1 $2" = "dist-tag ls" ]; then
  echo "latest: 7.0.1"
  [ -z "$SIM_NEXT" ] || echo "next: $SIM_NEXT"
fi
if [ "$1 $2" = "dist-tag add" ] && [ "$SIM_DIST_TAG_DENIED" = 1 ]; then
  exit 1
fi
if [ "$1" = pack ]; then
  destination=.
  if [ "${2:-}" = --pack-destination ]; then
    destination=$3
  fi
  stage=$(mktemp -d)
  mkdir "$stage/package"
  cp package.json "$stage/package/package.json"
  tar -czf "$destination/1inch-solidity-utils-${SIM_VERSION}.tgz" -C "$stage" package
  rm -r "$stage"
  if [ "$SIM_EXTRA_PACKAGE" = 1 ]; then
    cp "$destination/1inch-solidity-utils-${SIM_VERSION}.tgz" "$destination/1inch-solidity-utils-0.0.1.tgz"
  fi
fi
EOF
cat > "$sim/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "$SIM_LOG"
if [ "$1" = merge-base ] && [[ " $SIM_BRANCHES " != *" ${4:-} "* ]]; then
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
# The branches that hold the commit under test, for `git merge-base --is-ancestor`.
branches=origin/release/7.0.1
dry_run=false
npm_version=11.21.1
next_tag=
dist_tag_denied=0
extra_package=0
root_symlink=0
extra_artifact=0

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
  mkdir -p "$wd/runner-temp"
  if [ "$root_symlink" = 1 ]; then
    ln -s package.json "$wd/stray.tgz"
  fi
  if [ "$extra_artifact" = 1 ]; then
    cp "$wd/package/package.tgz" "$wd/package/second.tgz"
  fi
  : > "$wd/env"
  : > "$sim/calls"
  echo "$wd" > "$sim/last_wd"
  (
    export PATH="$sim/bin:$PATH" SIM_LOG="$sim/calls" SIM_RUNS="$sim/runs.json" SIM_TAG_EXISTS=$tag_exists SIM_BRANCHES=$branches DRY_RUN=$dry_run
    export SIM_VERSION=$version SIM_EXTRA_PACKAGE=$extra_package SIM_NPM_VERSION=$npm_version SIM_NEXT=$next_tag
    export SIM_DIST_TAG_DENIED=$dist_tag_denied
    export GITHUB_REPOSITORY=1inch/solidity-utils GITHUB_SHA=abc1234 GH_TOKEN=stub TAG_PREFIX=v
    export GITHUB_REF=$ref GITHUB_REF_NAME=${ref#refs/*/} GITHUB_ENV="$wd/env" GITHUB_OUTPUT="$wd/output" GITHUB_STEP_SUMMARY="$wd/summary" RUNNER_TEMP="$wd/runner-temp"
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

# run_workflow <workflow> <version> <ref> <inputs as JSON>
# Runs the workflow's jobs in order, as GitHub would for these inputs: a job runs when the jobs it needs succeeded and
# its `if` holds, and a step when its own `if` holds. `run` steps execute in the working directory, upload and download
# steps copy files through $wd/artifacts, and other `uses` steps are skipped. An `if` or `env` expression other than
# `inputs.<name>`, `!inputs.<name>`, `github.token` or `steps.<id>.outputs.<name>` stops the run with an error.
# Prints "ok", or the name of the first step that fails, and writes the jobs that ran to $sim/jobs.
run_workflow() {
  local wd
  wd=$(mktemp -d "$sim/wd.XXXX")
  printf '{"name":"@1inch/solidity-utils","version":"%s"}\n' "$2" > "$wd/package.json"
  mkdir -p "$wd/runner-temp"
  : > "$sim/calls"
  : > "$sim/jobs"
  echo "$wd" > "$sim/last_wd"
  PATH="$sim/bin:$PATH" SIM_LOG="$sim/calls" SIM_RUNS="$sim/runs.json" SIM_TAG_EXISTS=$tag_exists SIM_BRANCHES=$branches \
    SIM_VERSION=$2 SIM_EXTRA_PACKAGE=$extra_package SIM_NPM_VERSION=$npm_version SIM_NEXT=$next_tag \
    SIM_DIST_TAG_DENIED=$dist_tag_denied GITHUB_REPOSITORY=1inch/solidity-utils GITHUB_SHA=abc1234 \
    GITHUB_REF=$3 GITHUB_REF_NAME=${3#refs/*/} GITHUB_STEP_SUMMARY="$wd/summary" RUNNER_TEMP="$wd/runner-temp" \
    ruby - "$workflows/$1" "$wd" "$4" "$sim/jobs" <<'RUBY'
require "yaml"
require "json"
require "fileutils"

workflow_path, wd, inputs_json, jobs_file = ARGV
workflow = YAML.load_file(workflow_path)
declared = (workflow["on"] || workflow[true]).dig("workflow_call", "inputs") || {}
inputs = declared.to_h { |name, spec| [name, spec["default"]] }.merge(JSON.parse(inputs_json))

def evaluate(value, inputs, outputs)
  return value unless value.is_a?(String) && value.include?("${{")
  inner = value[/\A\$\{\{(.*)\}\}\z/m, 1] or raise "unsupported expression: #{value}"
  case inner.strip
  when /\A!inputs\.([\w-]+)\z/ then !inputs.fetch($1)
  when /\Ainputs\.([\w-]+)\z/ then inputs.fetch($1)
  when "github.token" then "stub"
  when /\Asteps\.([\w-]+)\.outputs\.([\w-]+)\z/ then outputs.fetch($1, {}).fetch($2, "")
  else raise "unsupported expression: #{value}"
  end
end

def pairs(path)
  File.readlines(path, chomp: true).map { |line| line.split("=", 2) if line.include?("=") }.compact.to_h
end

results = {}
ran = []
failed = nil
log = File.join(wd, "log")
workflow["jobs"].each do |job_name, job|
  ready = Array(job["needs"]).all? { |need| results[need] == :success }
  unless ready && (!job.key?("if") || evaluate(job["if"], inputs, {}) == true)
    results[job_name] = :skipped
    next
  end
  ran << job_name
  results[job_name] = :success
  env_file = File.join(wd, "env.#{job_name}")
  File.write(env_file, "")
  job_env = {}
  outputs = {}
  job["steps"].each_with_index do |step, index|
    next if step.key?("if") && evaluate(step["if"], inputs, outputs) != true
    with = step["with"] || {}
    ok =
      if step["run"]
        output_file = File.join(wd, "output.#{job_name}.#{index}")
        File.write(output_file, "")
        step_env = (step["env"] || {}).to_h { |key, value| [key, evaluate(value, inputs, outputs).to_s] }
        env = job_env.merge(step_env).merge("GITHUB_ENV" => env_file, "GITHUB_OUTPUT" => output_file)
        passed = system(env, "bash", "-e", "-c", step["run"], chdir: wd, out: [log, "a"], err: [:child, :out])
        job_env.merge!(pairs(env_file))
        outputs[step["id"]] = pairs(output_file) if step["id"]
        passed
      elsif step["uses"].to_s.include?("actions/upload-artifact")
        pattern = evaluate(with["path"], inputs, outputs).to_s
        files = pattern.empty? ? [] : Dir.glob(pattern, base: wd).map { |file| File.expand_path(file, wd) }
        destination = File.join(wd, "artifacts", with["name"])
        FileUtils.mkdir_p(destination)
        files.each { |file| FileUtils.cp(file, destination) }
        !(files.empty? && with["if-no-files-found"] == "error")
      elsif step["uses"].to_s.include?("actions/download-artifact")
        source = File.join(wd, "artifacts", with["name"])
        destination = File.join(wd, with["path"] || ".")
        FileUtils.mkdir_p(destination)
        Dir.exist?(source) && Dir.children(source).each { |file| FileUtils.cp(File.join(source, file), destination) }
      else
        true
      end
    next if ok
    results[job_name] = :failure
    failed ||= step["name"]
    break
  end
end
File.write(jobs_file, ran.map { |job| "#{job}\n" }.join)
puts failed || "ok"
RUBY
}

# check_workflow <title> <"ok" or the step that must fail> <regex for the npm calls, or "-" for none> <jobs that must run> <workflow> <version> <ref> <inputs as JSON>
check_workflow() {
  local title=$1 expected=$2 calls=$3 jobs=$4
  shift 4
  local got recorded ran calls_match=false
  got=$(run_workflow "$@" 2>&1)
  recorded=$(grep -E '^npm ' "$sim/calls" | tr '\n' ' ')
  ran=$(tr '\n' ' ' < "$sim/jobs")
  if [ "$calls" = - ]; then
    [ -z "$recorded" ] && calls_match=true
  elif [[ "$recorded" =~ $calls ]]; then
    calls_match=true
  fi
  if [ "$got" = "$expected" ] && $calls_match && [ "$ran" = "$jobs " ]; then
    echo "ok   $title"
  else
    echo "FAIL $title: expected \"$expected\", calls /$calls/ and jobs \"$jobs\", got \"$got\", calls \"$recorded\" and jobs \"$ran\""
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

upload_path=$(ruby -ryaml -e '
  step = YAML.load_file(ARGV[0])["jobs"]["build"]["steps"].find { |s| s["name"] == "Upload package" }
  print step["with"]["path"].to_s
' "$workflows/publish.yml")
if [ "$upload_path" = '${{ steps.pack.outputs.package }}' ]; then
  echo "ok   PUBLISH uploads only the file Pack wrote"
else
  echo "FAIL PUBLISH uploads only the file Pack wrote: got \"$upload_path\""
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
check "TAG a release candidate from release/7.1.0" ok 'git/refs -f ref=refs/tags/v7\.1\.0-rc\.1 ' tag.yml 7.1.0-rc.1 refs/heads/release/7.1.0 "${tag_steps[@]}"
check "TAG a release candidate from release/7.1.0-rc.1" "Check the release branch" - tag.yml 7.1.0-rc.1 refs/heads/release/7.1.0-rc.1 "${tag_steps[@]}"
check "TAG a release candidate from main" "Check the release branch" - tag.yml 7.1.0-rc.1 refs/heads/main "${tag_steps[@]}"
check "TAG a pre-release other than a release candidate" "Check the release branch" - tag.yml 7.1.0-beta.1 refs/heads/release/7.1.0-beta.1 "${tag_steps[@]}"
check "TAG a release candidate without its number" "Check the release branch" - tag.yml 7.1.0-rc refs/heads/release/7.1.0-rc "${tag_steps[@]}"

check "CREATE_RELEASE from v7.0.1" ok - release.yml 7.0.1 refs/tags/v7.0.1 "Find the release tag"
check "CREATE_RELEASE from v7.1.0-rc.1" ok - release.yml 7.1.0-rc.1 refs/tags/v7.1.0-rc.1 "Find the release tag"
check "CREATE_RELEASE from release/7.0.1" "Find the release tag" - release.yml 7.0.1 refs/heads/release/7.0.1 "Find the release tag"
check "CREATE_RELEASE from v7.0.0 while package.json says 7.0.1" "Find the release tag" - release.yml 7.0.1 refs/tags/v7.0.0 "Find the release tag"

publish_build_steps=("Check the release tag" "Check the release branch" "Check CI on the tag commit")
ci_run success
check "PUBLISH build from tested release tag" ok - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
branches=origin/main
check "PUBLISH rejects tag off release branch" "Check the release branch" - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
branches=origin/release/7.1.0
check "PUBLISH build from a release candidate tag on release/7.1.0" ok - publish.yml 7.1.0-rc.1 refs/tags/v7.1.0-rc.1 "${publish_build_steps[@]}"
branches=origin/release/7.1.0-rc.1
check "PUBLISH rejects a release candidate tag that only release/7.1.0-rc.1 holds" "Check the release branch" - publish.yml 7.1.0-rc.1 refs/tags/v7.1.0-rc.1 "${publish_build_steps[@]}"
branches=origin/release/7.0.1
ci_run failure
check "PUBLISH rejects tag without passed CI" "Check CI on the tag commit" - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
ci_run success workflow_dispatch
check "PUBLISH accepts dispatched CI" ok - publish.yml 7.0.1 refs/tags/v7.0.1 "${publish_build_steps[@]}"
check "PUBLISH from v7.0.1" ok '^npm publish \./package/package\.tgz $' publish.yml 7.0.1 refs/tags/v7.0.1 "Publish"
check "PUBLISH a pre-release from v7.1.0-rc.1" ok '^npm publish \./package/package\.tgz --tag next $' publish.yml 7.1.0-rc.1 refs/tags/v7.1.0-rc.1 "Publish"
dry_run=true
check "PUBLISH dry-run" ok '^npm publish \./package/package\.tgz --dry-run $' publish.yml 7.0.1 refs/tags/v7.0.1 "Publish"
dry_run=false
packed='^npm pack --pack-destination [^ ]*/runner-temp/npm-package\.[^ ]* $'

# check_packed_output <title>: the last run's Pack output names the packed file, and the summary holds its integrity.
check_packed_output() {
  local pack_wd package integrity
  pack_wd=$(cat "$sim/last_wd")
  package=$(sed -n 's/^package=//p' "$pack_wd/output" 2>/dev/null)
  integrity="sha512-$(openssl dgst -sha512 -binary "$package" 2>/dev/null | openssl base64 -A)"
  if [[ "$package" == "$pack_wd"/runner-temp/npm-package.*/1inch-solidity-utils-7.0.1.tgz ]] && grep -qF "\`${integrity}\`" "$pack_wd/summary" 2>/dev/null; then
    echo "ok   $1"
  else
    echo "FAIL $1: package=\"$package\""
    failures=$((failures + 1))
  fi
}

check "PUBLISH packs one package" ok "$packed" publish.yml 7.0.1 refs/tags/v7.0.1 "Pack"
check_packed_output "PUBLISH outputs the packed file and writes its integrity to the run summary"
root_symlink=1
check "PUBLISH packs next to a *.tgz symlink in the checkout" ok "$packed" publish.yml 7.0.1 refs/tags/v7.0.1 "Pack"
check_packed_output "PUBLISH outputs the packed file, not the symlink"
root_symlink=0
extra_package=1
check "PUBLISH refuses a second tarball from npm pack" "Pack" "$packed" publish.yml 7.0.1 refs/tags/v7.0.1 "Pack"
extra_package=0
extra_artifact=1
check "PUBLISH refuses an artifact with a second file" "Publish" - publish.yml 7.0.1 refs/tags/v7.0.1 "Publish"
extra_artifact=0

listed='^npm --version npm dist-tag ls @1inch/solidity-utils $'
moved='npm dist-tag ls @1inch/solidity-utils npm dist-tag add @1inch/solidity-utils@7\.1\.0 next $'
next_tag=7.1.0-rc.2
check "PUBLISH moves next from 7.1.0-rc.2 to the release 7.1.0" ok "^npm --version $moved" publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
check "PUBLISH moves no tag for a release candidate" ok - publish.yml 7.1.0-rc.3 refs/tags/v7.1.0-rc.3 "Move next to the release"
dry_run=true
check "PUBLISH dry-run leaves next on 7.1.0-rc.2" ok "$listed" publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
dry_run=false
next_tag=7.2.0-rc.1
check "PUBLISH leaves next on a release candidate of a later version" ok "$listed" publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
next_tag=
check "PUBLISH leaves next unset" ok "$listed" publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
next_tag=7.1.0-rc.2
npm_version=11.20.0
check "PUBLISH leaves next to a package admin on npm 11.20.0" ok '^npm --version $' publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
npm_version=12.1.0
check "PUBLISH leaves next to a package admin on npm 12.1.0" ok '^npm --version $' publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
npm_version=12.2.0
check "PUBLISH moves next on npm 12.2.0" ok "^npm --version $moved" publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
npm_version=11.21.1
dist_tag_denied=1
check "PUBLISH fails when npm refuses to move next" "Move next to the release" "^npm --version $moved" publish.yml 7.1.0 refs/tags/v7.1.0 "Move next to the release"
dist_tag_denied=0
next_tag=

published='npm publish \./package/1inch-solidity-utils-7\.0\.1\.tgz $'
check_workflow "PUBLISH pack-only runs the build job and publishes nothing" ok "$packed" build publish.yml 7.0.1 refs/tags/v7.0.1 '{"pack-only": true}'
artifact=$(ls "$(cat "$sim/last_wd")/artifacts/npm-package" 2>/dev/null | tr '\n' ' ')
if [ "$artifact" = "1inch-solidity-utils-7.0.1.tgz " ]; then
  echo "ok   PUBLISH pack-only leaves the package in the npm-package artifact"
else
  echo "FAIL PUBLISH pack-only leaves the package in the npm-package artifact: got \"$artifact\""
  failures=$((failures + 1))
fi
check_workflow "PUBLISH publishes the package the build job packed" ok "${packed%\$}$published" "build npm" publish.yml 7.0.1 refs/tags/v7.0.1 '{}'
rc_published='npm publish \./package/1inch-solidity-utils-7\.1\.0-rc\.1\.tgz --tag next $'
branches=origin/release/7.1.0
check_workflow "PUBLISH publishes a release candidate from release/7.1.0 under next" ok "${packed%\$}$rc_published" "build npm" publish.yml 7.1.0-rc.1 refs/tags/v7.1.0-rc.1 '{}'
next_tag=7.1.0-rc.2
check_workflow "PUBLISH with move-next publishes 7.1.0 and moves next to it" ok "${packed%\$}npm publish \./package/1inch-solidity-utils-7\.1\.0\.tgz npm --version $moved" "build npm" publish.yml 7.1.0 refs/tags/v7.1.0 '{"move-next": true}'
check_workflow "PUBLISH without move-next leaves next on 7.1.0-rc.2" ok "${packed%\$}npm publish \./package/1inch-solidity-utils-7\.1\.0\.tgz \$" "build npm" publish.yml 7.1.0 refs/tags/v7.1.0 '{}'
next_tag=
branches=origin/release/7.0.1
check_workflow "PUBLISH pack-only from main stops before packing" "Check the release tag" - build publish.yml 7.0.1 refs/heads/main '{"pack-only": true}'
check "PUBLISH from main" "Check the release tag" - publish.yml 7.0.1 refs/heads/main "Check the release tag" "Publish"

if [ "$failures" -gt 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "All scenarios passed"
