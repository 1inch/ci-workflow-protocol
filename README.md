# ci-workflow-protocol

Shared GitHub Actions workflows and the release flow of the 1inch contract repositories: solidity-utils, aqua, swap-vm, limit-order-protocol, fusion-protocol and cross-chain-swap.

- [RELEASE_FLOW.md](RELEASE_FLOW.md): branches, versions, tags and deployment artifacts.
- [.github/workflows](.github/workflows): reusable workflows. Each repository keeps only short callers, plus any job that only it needs.
- [.github/actions](.github/actions): the steps the CI workflows share.
  - [setup](.github/actions/setup/action.yml) starts every job. It checks out the commit under test without persisted credentials, sets up Node.js 24 with the Yarn cache and runs `yarn install --frozen-lockfile`.
  - [hardhat](.github/actions/hardhat/action.yml) restores and saves Hardhat's build cache in the `test` job of `hardhat-ci.yml`.
  - [foundry](.github/actions/foundry/action.yml) installs Foundry in every job of `foundry-ci.yml` and caches its build output in the `test` job.

| Shared workflow | Caller in the repository | What it does |
|---|---|---|
| `hardhat-ci.yml` | `ci.yml` in a Hardhat repository | `yarn test`, plus `yarn typecheck`, `yarn snapshot:check`, `yarn lint` and `yarn coverage` where enabled, with Hardhat's build cache |
| `foundry-ci.yml` | `ci.yml` in a Foundry repository | The same jobs, with Foundry installed and its build output cached |
| `tag.yml` | `tag.yml` | Tags the `package.json` version on the head of `release/X.Y.Z`, run by hand |
| `release.yml` | `release.yml` | Creates the GitHub Release for the tag of the `package.json` version |
| `publish.yml` | `publish.yml` | Publishes the package to npm with trusted publishing |

## Versions

Callers reference a release of this repository, such as `@v2.0.0`, and never a branch. A change merged here reaches a repository only when that repository merges a pull request that moves its callers to the release containing it. The change shows up as a commit in every repository, and moving the callers back reverts it.

The release, publish and tag workflows run with `contents: write` or `id-token: write` in the calling repository. Because callers pin a release, a merge into `main` here does not change what can publish a package. Releases are immutable, so a published tag can be neither moved nor deleted, and a tag ruleset lets only repository admins create, move or delete `v*` tags, which covers a tag before its release is published. A caller references a tag only once its release is published.

To ship a change:

1. Try it from a branch first, by pointing one repository's pull request at that branch. Keep inputs backward-compatible: a new input is optional and defaults to the old behaviour.
2. Merge it into `main` through a reviewed pull request. The `Self-test` workflow runs `test/release-workflows.sh` on it, which runs the steps of the tag, release and publish workflows against fixed scenarios with `gh` and `npm` stubbed. Run it locally with `bash test/release-workflows.sh`; it needs `jq` and `ruby`.
3. Publish a release from `main`: a patch for a fix, a minor for a new input, a major for a change that callers have to adapt to. Immutable releases are enabled in this repository's settings, so the tag cannot move:

   ```bash
   gh release create v2.0.1 --repo 1inch/ci-workflow-protocol --target main --generate-notes
   ```

4. In each repository, open a pull request that moves every caller to the new tag. Everything a repository references here, its callers and the actions alike, names the same release.

The CI workflows call their actions as `$/.github/actions/...`. GitHub resolves `$/` to this repository at the commit that is running, so a caller pinned to a release also runs the actions of that release.

## CI

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  ci:
    uses: 1inch/ci-workflow-protocol/.github/workflows/hardhat-ci.yml@v2.0.0
    with:
      profile: default
      sources: contracts
      snapshot: false
      lint: true
```

A Foundry repository calls `foundry-ci.yml` in the same way. Both workflows take the same inputs, and `foundry-ci.yml` also takes `foundry-version`.

| Input | Type | Default | Meaning |
|---|---|---|---|
| `foundry-version` | string | `v1.5.1` | `foundry-ci.yml` only: the Foundry version every job installs |
| `profile` | string | `default` | Build profile that `yarn test` uses, for the artifact cache key |
| `sources` | string | `contracts` | Contract source directory, for the artifact cache key |
| `snapshot` | boolean | `false` | Run the `snapshot` job, `yarn snapshot:check`. Enable it where gas snapshots are tracked |
| `lint` | boolean | `false` | Run the `lint` job, `yarn lint`. Enable it where a linter is configured |
| `typecheck` | boolean | `false` | Run `yarn typecheck` in the `test` job, after `yarn test` has generated the types. Enable it where the repository has a `typecheck` script |
| `coverage` | boolean | `false` | Run the `coverage` job, `yarn coverage`, and upload the report to Codecov. Enable it where the repository is set up on Codecov |

Both workflows run the same jobs on the repository's own `package.json` scripts, so what a repository runs behind `yarn test` or `yarn lint` is its own choice. They differ only in the toolchain step:

- In `hardhat-ci.yml`, the `test` job restores and saves `artifacts` and `cache` through `.github/actions/hardhat`, under a key of `profile`, `hardhat.config.ts`, `yarn.lock` and `<sources>/**/*.sol`.
- In `foundry-ci.yml`, every job checks out submodules and installs Foundry through `.github/actions/foundry`. The `test` job also caches `out` and `cache`, under a key of `profile`, `foundry.toml`, `foundry.lock`, `remappings.txt`, `yarn.lock` and `<sources>/**/*.sol`.

With `coverage: true`, the caller also passes the Codecov token:

```yaml
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

The checks are reported as `ci / test`, `ci / snapshot`, `ci / lint` and `ci / coverage`; require exactly the ones a repository runs on `main`, plus its own jobs. Only the `coverage` job reads a secret. A failed upload does not fail the job, so pull requests from forks, which get no secrets, still pass CI.

### Jobs of a repository's own

A check that only one repository needs stays in that repository, as a plain job next to `ci` in `ci.yml`. cross-chain-swap keeps the Foundry build of its deployers this way:

```yaml
jobs:
  ci:
    uses: 1inch/ci-workflow-protocol/.github/workflows/hardhat-ci.yml@v2.0.0
    with:
      profile: default
      sources: contracts
      snapshot: true
      lint: true
      typecheck: true
      coverage: true
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}

  forge-build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: 1inch/ci-workflow-protocol/.github/actions/setup@v2.0.0

      - uses: 1inch/ci-workflow-protocol/.github/actions/foundry@v2.0.0

      - name: Build the Foundry deployers
        run: yarn deployers:foundry && forge build
```

The job runs on the caller's triggers, concurrency and read-only permissions, and reports as `forge-build` next to `ci / test` and the other shared checks. Require it on `main` like them. It reuses the shared setup and Foundry actions at the same release as the `ci` job, so it installs the same Foundry version as `foundry-ci.yml`. From another repository an action takes the full path and the tag, because `$/` would point at the calling repository. When a second repository needs the same check, it moves into the shared workflow as an optional input.

## Releases

Every repository follows [RELEASE_FLOW.md](RELEASE_FLOW.md) and has the tag, the GitHub Release and the publish workflows. A release branch is cut from `main` and never changes, so no workflow runs on pull requests into it.

### Tag

`.github/workflows/tag.yml`, run by hand from `release/X.Y.Z` once the release is ready. It takes the version from `package.json` on that branch, tags the branch's head with it, and refuses to run from any branch other than `release/<that version>`:

```yaml
name: TAG
on:
  workflow_dispatch:

permissions:
  contents: write
  actions: read

jobs:
  tag:
    uses: 1inch/ci-workflow-protocol/.github/workflows/tag.yml@v2.0.0
```

| Input | Type | Default | Meaning |
|---|---|---|---|
| `tag-prefix` | string | `v` | Text in front of the `package.json` version in the tag. The release flow uses `v`; the GitHub Release and the publish workflows take the same input |

It also refuses a commit without a passed `CI` run from its push to `main`. `actions: read` lets it read that run, so the repository's CI workflow must be named `CI`, as the caller above is.

When the tag already exists, GitHub refuses to create it again and the run fails, so a tag is never moved. A tag created this way does not start other workflows, so `CREATE_RELEASE` and `PUBLISH` are run by hand from it.

### GitHub Release

`.github/workflows/release.yml`, run by hand from the tag:

```yaml
name: CREATE_RELEASE
on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    uses: 1inch/ci-workflow-protocol/.github/workflows/release.yml@v2.0.0
    with:
      tag-prefix: v
      changelog: false
```

| Input | Type | Default | Meaning |
|---|---|---|---|
| `tag-prefix` | string | `v` | Text in front of the `package.json` version in the tag: `v` for `v1.2.3`, empty for `1.2.3` |
| `changelog` | boolean | `false` | Take the notes from `yarn changelog --stdout`, where each release starts with a `<repository>/<version> (<date>)` line, as solidity-utils' auto-changelog template writes it. Otherwise GitHub generates the notes from the merged pull requests |

The workflow runs only from the tag made of `tag-prefix` and the `package.json` version, so the tag already exists. Started from a branch or another tag, it fails. It never creates or moves a tag. A version with a pre-release part, such as `2.2.0-rc.1`, becomes a pre-release.

### npm

`.github/workflows/publish.yml`, run by hand from the tag:

```yaml
name: PUBLISH
on:
  workflow_dispatch:

permissions:
  contents: read
  id-token: write

jobs:
  publish-npmjs:
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish.yml@v2.0.0
```

The workflow runs only from the tag made of `tag-prefix` (`v` by default) and the `package.json` version, and fails without publishing when started from a branch or another tag. Packages go to npm only, not to GitHub Packages.

A pre-release goes to the `next` dist-tag, and every other version becomes `latest`.

The job runs in the calling repository's `npm` environment. Create it in the repository settings before the first run, because GitHub creates an unprotected environment on first use:

- deployment branches and tags: only the tag pattern `v*`;
- required reviewers: the repository's maintainers, so every publish waits for an approval.

npm publishing uses [trusted publishing](https://docs.npmjs.com/trusted-publishers/), so no npm token is stored anywhere. Before the first run, a package admin adds a trusted publisher in the package settings on npmjs.com:

- organization `1inch` and the repository's name;
- workflow filename `publish.yml`, with `npm publish` allowed;
- environment `npm`.

`workflow_dispatch` runs the caller file of the ref it is started from, so someone with write access could push a branch with a rewritten `publish.yml` that skips the tag check. The environment is what such a file cannot get around: npm refuses a publish from outside `npm`, and GitHub does not start a job in `npm` from a branch.

For a reusable workflow npm checks the caller's filename, so the caller must be named `publish.yml`. The shared workflow has the same name, so the check passes whichever file npm reads. The package's `repository.url` in `package.json` must name the same repository.

npm adds a trusted publisher only to a package that already exists, so a package admin publishes a new package's first version by hand, from its tag, with `"publishConfig": { "access": "public" }` in `package.json` for a scoped package. A trusted publisher that has not published within two days expires, so add it right before the first publish from CI. Trusted publishers created since 2026-09-03 allow only `npm stage publish` unless `npm publish` is also selected, and this workflow runs `npm publish`.
