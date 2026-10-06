# ci-workflow-protocol

Shared GitHub Actions workflows and the release flow of the 1inch contract repositories: solidity-utils, aqua, swap-vm, limit-order-protocol, fusion-protocol and cross-chain-swap.

- [RELEASE_FLOW.md](RELEASE_FLOW.md): branches, versions, tags and deployment artifacts.
- [.github/workflows](.github/workflows): reusable workflows. Each repository keeps only short callers.

| Shared workflow | Caller in the repository | What it does |
|---|---|---|
| `hardhat-ci.yml` | `ci.yml` | `yarn test`, plus `yarn typecheck`, `yarn snapshot:check`, `yarn lint` and `yarn coverage` where enabled |
| `check-version.yml` | `cpv.yml` | Fails a pull request into `release/X.Y.Z` that sets another version, or that arrives after the tag exists |
| `tag.yml` | `tag.yml` | Tags the `package.json` version on the head of `release/X.Y.Z`, run by hand |
| `release.yml` | `release.yml` | Creates the GitHub Release for the tag of the `package.json` version |
| `publish.yml` | `publish.yml` | Publishes the package to npm with trusted publishing |
| `publish-github-packages.yml` | `publish.yml` | Publishes the package to GitHub Packages |

## Versions

Callers reference `master`, so a change reaches every repository as soon as it merges here. Try it from a branch first, by pointing one repository's pull request at that branch, and keep inputs backward-compatible: a new input is optional and defaults to the old behaviour.

The release, publish and tag workflows run with `contents: write`, `id-token: write` or `packages: write` in the calling repository, so a merge into `master` here changes what can publish its package. Protect `master` with a required review.

## CI

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [master, 'release/**']

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  ci:
    uses: 1inch/ci-workflow-protocol/.github/workflows/hardhat-ci.yml@master
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

The checks are reported as `ci / test`, `ci / snapshot`, `ci / lint` and `ci / coverage`; require exactly the ones a repository runs on `master`. Only the `coverage` job reads a secret. A failed upload does not fail the job, so pull requests from forks, which get no secrets, still pass CI.

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
    uses: 1inch/ci-workflow-protocol/.github/workflows/check-version.yml@master
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
    uses: 1inch/ci-workflow-protocol/.github/workflows/tag.yml@master
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
    uses: 1inch/ci-workflow-protocol/.github/workflows/release.yml@master
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
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish.yml@master
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
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish.yml@master

  github-packages:
    permissions:
      contents: read
      packages: write
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish-github-packages.yml@master
```

npm publishing uses [trusted publishing](https://docs.npmjs.com/trusted-publishers/), so no npm token is stored anywhere. Before the first run, a package admin adds a trusted publisher in the package settings on npmjs.com:

- organization `1inch` and the repository's name;
- workflow filename `publish.yml`, with `npm publish` allowed.

For a reusable workflow npm checks the caller's filename, so the caller must be named `publish.yml`. The shared workflow has the same name, so the check passes whichever file npm reads. The package's `repository.url` in `package.json` must name the same repository.
