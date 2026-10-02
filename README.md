# ci-workflow-protocol

Shared GitHub Actions workflows and the release flow of the 1inch contract repositories: solidity-utils, aqua, swap-vm, limit-order-protocol, fusion-protocol and cross-chain-swap.

- [RELEASE_FLOW.md](RELEASE_FLOW.md): branches, versions, tags and deployment artifacts.
- [.github/workflows](.github/workflows): reusable workflows. Each repository keeps only short callers.

| Shared workflow | Caller in the repository | What it does |
|---|---|---|
| `hardhat-ci.yml` | `ci.yml` | `yarn test`, plus `yarn snapshot:check` and `yarn lint` where enabled |
| `check-version.yml` | `cpv.yml` | Fails a pull request whose `package.json` version is not above the latest on npm |
| `release.yml` | `release.yml` | Creates the GitHub Release for the tag of the `package.json` version |
| `publish.yml` | `publish.yml` | Publishes the package to npm with trusted publishing |
| `publish-github-packages.yml` | `publish.yml` | Publishes the package to GitHub Packages |

## Versions

Callers reference a tag of this repository, never a branch. Every release gets an immutable tag such as `v1.0.0`, and the major tag `v1` moves to the newest release in that major.

A change is first tried from one repository's pull request whose caller references the change's branch. `v1` moves only after that run is green. A change that breaks callers, such as a new required input or a removed job, gets `v2`.

## CI

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [master]

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  ci:
    uses: 1inch/ci-workflow-protocol/.github/workflows/hardhat-ci.yml@v1
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

The checks are reported as `ci / test`, `ci / snapshot` and `ci / lint`; require exactly the ones a repository runs on `master`. CI reads no secrets, so pull requests from forks run it too.

## Releases

For repositories that publish an npm package. [RELEASE_FLOW.md](RELEASE_FLOW.md) says when a tag is created; these workflows run once it exists.

### Version check

`.github/workflows/cpv.yml`, for a repository where every pull request into `master` raises the version, such as solidity-utils:

```yaml
name: CHECK_PACKAGE_VERSION
on:
  pull_request:
    branches: [master]

permissions:
  contents: read

jobs:
  check-package-version:
    uses: 1inch/ci-workflow-protocol/.github/workflows/check-version.yml@v1
```

A package that is not on npm yet passes.

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
    uses: 1inch/ci-workflow-protocol/.github/workflows/release.yml@v1
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
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish.yml@v1
```

To also publish to GitHub Packages, add `packages: write` to `permissions` and a second job:

```yaml
  github-packages:
    uses: 1inch/ci-workflow-protocol/.github/workflows/publish-github-packages.yml@v1
```

npm publishing uses [trusted publishing](https://docs.npmjs.com/trusted-publishers/), so no npm token is stored anywhere. Before the first run, a package admin adds a trusted publisher in the package settings on npmjs.com:

- organization `1inch` and the repository's name;
- workflow filename `publish.yml`, with `npm publish` allowed.

For a reusable workflow npm checks the caller's filename, so the caller must be named `publish.yml`. The shared workflow has the same name, so the check passes whichever file npm reads. The package's `repository.url` in `package.json` must name the same repository.
