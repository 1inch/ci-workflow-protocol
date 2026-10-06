# ci-workflow-protocol

Shared GitHub Actions workflows and the release flow of the 1inch contract repositories: solidity-utils, aqua, swap-vm, limit-order-protocol, fusion-protocol and cross-chain-swap.

- [RELEASE_FLOW.md](RELEASE_FLOW.md): branches, versions, tags and deployment artifacts.
- [.github/workflows](.github/workflows): reusable workflows. Each repository keeps only short callers, plus any job that only it needs.

| Shared workflow | Caller in the repository | What it does |
|---|---|---|
| `hardhat-ci.yml` | `ci.yml` | `yarn test`, plus `yarn typecheck`, `yarn snapshot:check`, `yarn lint` and `yarn coverage` where enabled |
| `check-version.yml` | `cpv.yml` | Fails a pull request into `release/X.Y.Z` that sets another version, or that arrives after the tag exists |
| `tag.yml` | `tag.yml` | Tags the `package.json` version on the head of `release/X.Y.Z`, run by hand |
| `release.yml` | `release.yml` | Creates the GitHub Release for the tag of the `package.json` version |
| `publish.yml` | `publish.yml` | Publishes the package to npm with trusted publishing |
| `publish-github-packages.yml` | `publish.yml` | Publishes the package to GitHub Packages |

## Versions

Callers reference a release of this repository, such as `@v1.0.0`, and never a branch. A change merged here reaches a repository only when that repository merges a pull request that moves its callers to the release containing it. The change shows up as a commit in every repository, and moving the callers back reverts it.

The release, publish and tag workflows run with `contents: write`, `id-token: write` or `packages: write` in the calling repository. Because callers pin a release, a merge into `main` here does not change what can publish a package. Releases are immutable, so a published tag can be neither moved nor deleted.

To ship a change:

1. Try it from a branch first, by pointing one repository's pull request at that branch. Keep inputs backward-compatible: a new input is optional and defaults to the old behaviour.
2. Merge it into `main` through a reviewed pull request.
3. Publish a release from `main`: a patch for a fix, a minor for a new input, a major for a change that callers have to adapt to. Immutable releases are enabled in this repository's settings, so the tag cannot move:

   ```bash
   gh release create v1.0.1 --repo 1inch/ci-workflow-protocol --target main --generate-notes
   ```

4. In each repository, open a pull request that moves every caller to the new tag. A repository's callers always reference the same release.

## CI

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main, 'release/**']

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  ci:
    uses: 1inch/ci-workflow-protocol/.github/workflows/hardhat-ci.yml@v1.0.0
    with:
      profile: default
      sources: contracts
      snapshot: false
      lint: true
```

| Input | Type | Default | Meaning |
|---|---|---|---|
| `profile` | string | `default` | Build profile that `yarn test` uses, for the artifact cache key |
| `sources` | string | `contracts` | Contract source directory, for the artifact cache key |
| `snapshot` | boolean | `false` | Run the `snapshot` job, `yarn snapshot:check`. Enable it where gas snapshots are tracked |
| `lint` | boolean | `false` | Run the `lint` job, `yarn lint`. Enable it where a linter is configured |
| `typecheck` | boolean | `false` | Run `yarn typecheck` in the `test` job, after `yarn test` has generated the types. Enable it where the repository has a `typecheck` script |
| `coverage` | boolean | `false` | Run the `coverage` job, `yarn coverage`, and upload the report to Codecov. Enable it where the repository is set up on Codecov |

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
    uses: 1inch/ci-workflow-protocol/.github/workflows/hardhat-ci.yml@v1.0.0
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
      - uses: actions/checkout@v7
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          persist-credentials: false

      - name: Setup Node.js
        uses: actions/setup-node@v6
        with:
          node-version: 24
          cache: yarn

      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
        with:
          version: v1.5.1

      - name: Install node modules
        run: yarn install --frozen-lockfile

      - name: Build the Foundry deployers
        run: yarn deployers:foundry && forge build
```

The job runs on the caller's triggers, concurrency and read-only permissions, and reports as `forge-build` next to `ci / test` and the other shared checks. Require it on `main` like them. Like the shared jobs, it checks out the pull request's head without persisted credentials. When a second repository needs the same check, it moves into the shared workflow as an optional input.

## Releases

Every repository follows [RELEASE_FLOW.md](RELEASE_FLOW.md) and has the version check, the tag and the GitHub Release workflows. Repositories that publish an npm package also have the publish workflow.

### Version check

`.github/workflows/cpv.yml`, on pull requests into a release branch:

```yaml
name: CHECK_PACKAGE_VERSION
on:
  pull_request:
    branches: ['release/**']

permissions:
  contents: read

jobs:
  check-package-version:
    uses: 1inch/ci-workflow-protocol/.github/workflows/check-version.yml@v1.0.0
```

A pull request into `release/X.Y.Z` fails when it sets `package.json` to a version other than `X.Y.Z`, and once the tag `vX.Y.Z` exists, because the branch is then frozen. A pull request that leaves the version as it is passes; `TAG` takes the version from `package.json` when the release is ready.

### Tag

`.github/workflows/tag.yml`, run by hand from `release/X.Y.Z` once the release is ready. It takes the version from `package.json` on that branch, tags the branch's head with it, and refuses to run from any branch other than `release/<that version>`:

```yaml
name: TAG
on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  tag:
    uses: 1inch/ci-workflow-protocol/.github/workflows/tag.yml@v1.0.0
```

| Input | Type | Default | Meaning |
|---|---|---|---|
| `tag-prefix` | string | `v` | Text in front of the `package.json` version in the tag. The release flow uses `v`; the version check and the GitHub Release workflow take the same input |

When the tag already exists, the version has not changed and the workflow does nothing: it never moves a tag. A tag created this way does not start other workflows, so `CREATE_RELEASE` and `PUBLISH` are run by hand from it.

### GitHub Release

`.github/workflows/release.yml`, run by hand once the tag exists:

```yaml
name: CREATE_RELEASE
on:
  workflow_dispatch:

permissions:
  contents: write

jobs:
  release:
    uses: 1inch/ci-workflow-protocol/.github/workflows/release.yml@v1.0.0
    with:
      tag-prefix: v
      changelog: false
```

| Input | Type | Default | Meaning |
|---|---|---|---|
| `tag-prefix` | string | `v` | Text in front of the `package.json` version in the tag: `v` for `v1.2.3`, empty for `1.2.3` |
| `changelog` | boolean | `false` | Take the notes from `yarn changelog --stdout`, where each release starts with a `<repository>/<version> (<date>)` line, as solidity-utils' auto-changelog template writes it. Otherwise GitHub generates the notes from the merged pull requests |

The tag must exist: the workflow fails without it and never creates or moves a tag. A version with a pre-release part, such as `2.2.0-rc.1`, becomes a pre-release.

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
  npm:
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish.yml@v1.0.0
```

To also publish to GitHub Packages, give each job its own permissions, so the npm job never holds `packages: write` and the GitHub Packages job never holds `id-token: write`:

```yaml
permissions:
  contents: read

jobs:
  npm:
    permissions:
      contents: read
      id-token: write
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish.yml@v1.0.0

  github-packages:
    permissions:
      contents: read
      packages: write
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish-github-packages.yml@v1.0.0
```

npm publishing uses [trusted publishing](https://docs.npmjs.com/trusted-publishers/), so no npm token is stored anywhere. Before the first run, a package admin adds a trusted publisher in the package settings on npmjs.com:

- organization `1inch` and the repository's name;
- workflow filename `publish.yml`, with `npm publish` allowed.

For a reusable workflow npm checks the caller's filename, so the caller must be named `publish.yml`. The shared workflow has the same name, so the check passes whichever file npm reads. The package's `repository.url` in `package.json` must name the same repository.
