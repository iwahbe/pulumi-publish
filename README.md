# pulumi-publish

A composite GitHub Action (and reusable workflow) that generates per-commit
Pulumi package artifacts — the package schema plus fully publishable SDKs —
and stores them on a dedicated branch of the repository, linked to the source
commits they were generated from.

## Getting Started

Run the pipeline on every commit to the default branch. The easiest way is the
reusable workflow — build the provider yourself, upload it as an artifact, and
hand everything else over:

```yaml
name: artifacts
on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: make provider   # however this repo builds bin/pulumi-resource-foo
      - uses: actions/upload-artifact@v7
        with:
          name: provider
          path: bin/pulumi-resource-foo

  publish:
    needs: build
    uses: iwahbe/pulumi-publish/.github/workflows/publish.yml@main
    permissions:
      contents: write
    with:
      provider-artifact: provider
      provider-binary: pulumi-resource-foo
      # branch: pulumi-artifacts                              # default
      # languages: '["go","nodejs","python","dotnet","java"]' # default
      # pulumi-version: latest                                # default
```

Or wire the action's modes yourself for full control. There are four modes:
`schema` runs `pulumi package get-schema` on a provider binary and uploads the
result as the `schema` artifact (it fails if the schema has no version);
`gen-sdk` downloads that artifact, runs `pulumi package gen-sdk`,
post-processes for publishability, and uploads the `sdk-<language>` artifact;
`commit` downloads the `schema` and `sdk-*` artifacts and commits them to the
artifacts branch; `dump` resolves a ref on the default
branch to its artifacts commit.

```yaml
jobs:
  schema:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: make provider
      - uses: pulumi/actions@v7
      - uses: iwahbe/pulumi-publish@main
        with:
          mode: schema
          provider-path: bin/pulumi-resource-foo

  sdks:
    needs: schema
    runs-on: ubuntu-latest
    strategy:
      matrix:
        language: [go, nodejs, python, dotnet, java]
    steps:
      - uses: pulumi/actions@v7
      - uses: iwahbe/pulumi-publish@main
        with:
          mode: gen-sdk
          language: ${{ matrix.language }}

  commit:
    needs: sdks
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v7
      - uses: iwahbe/pulumi-publish@main
        with:
          mode: commit
```

Consume the artifacts later — for example in a release workflow that wants the
prebuilt SDKs for the tagged commit:

```yaml
      - uses: actions/checkout@v7
      - uses: iwahbe/pulumi-publish@main
        id: artifacts
        with:
          mode: dump
          ref: ${{ github.ref_name }}   # a tag, sha, or branch on main
          path: prebuilt
      # prebuilt/schema.json and prebuilt/sdk/<language>/ are now on disk
      - run: echo "artifacts commit ${{ steps.artifacts.outputs.commit }}"
```

## Configuration

### Action

Inputs:

- `mode` - required. One of `schema`, `gen-sdk`, `commit`, or `dump`.
- `provider-path` - `schema` mode, required there: path to the built provider
  binary.
- `language` - `gen-sdk` mode, required there: one of `go`, `nodejs`,
  `python`, `dotnet`, or `java`.
- `branch` - `commit` and `dump` modes: the artifacts branch. Default
  `pulumi-artifacts`.
- `ref` - `dump` mode: committish on the default branch to look up. Default
  the current commit (`${{ github.sha }}`).
- `path` - `dump` mode, optional: if set, check the artifacts tree out into
  this directory.

Outputs:

- `commit` - the artifacts-branch commit SHA (`commit` and `dump` modes).

### Reusable workflow

Inputs:

- `provider-artifact` - required. Name of an already-uploaded artifact
  containing the provider binary.
- `provider-binary` - required. File name of the provider binary inside the
  artifact.
- `branch` - the artifacts branch to commit to. Default `pulumi-artifacts`.
- `languages` - JSON array of SDK languages to generate. Default
  `'["go","nodejs","python","dotnet","java"]'`.
- `pulumi-version` - Pulumi CLI version to install. Default `latest`.

Outputs:

- `commit` - the artifacts-branch commit SHA.

## How it works

Each pipeline run commits a tree of the form

```
schema.json
sdk/
  go/
  nodejs/
  python/
  dotnet/
  java/
```

to an artifacts branch (default `pulumi-artifacts`). The branch has its own
history, disjoint from the default branch: the first commit is parentless, and
each later commit replaces the whole tree on top of the previous one.

The two histories are linked in both directions:

- The artifacts commit names its source commit in a `Source-Commit:` trailer.
- A git note in `refs/notes/<branch>` on the source commit holds the artifacts
  commit SHA. Dump mode reads this note.

Both the branch push and the notes push retry on races, so concurrent runs are
safe and no `concurrency:` group is required. A source commit that already has
a note is skipped (the existing artifacts commit is returned); delete the note
to force regeneration.

`schema` and `gen-sdk` require the `pulumi` CLI on `PATH` (install it with
[`pulumi/actions`](https://github.com/pulumi/actions)). `commit` and `dump`
require an `actions/checkout` of the repository first; `commit` additionally
needs the `contents: write` permission.

`gen-sdk` post-processes the generated SDKs: Go SDKs get `go mod tidy` (the
action installs Go itself); dotnet SDKs get a `logo.png` — the generated
`.csproj` packs one unconditionally, but codegen fills it with the schema's
`logoUrl` bytes verbatim (or, on older CLIs, not at all), so the action
fetches the logo if it is missing and rasterizes it to PNG if it is an SVG.

Locally, dump is two git commands:

```sh
git fetch origin '+refs/notes/pulumi-artifacts:refs/notes/pulumi-artifacts'
git notes --ref=pulumi-artifacts show <main-sha>   # prints the artifacts sha
```

Caveats:

- Notes bind to the exact SHA: rebasing or force-pushing the default branch
  orphans the mapping for the rewritten commits.
- Artifact names `schema` and `sdk-<language>` are fixed conventions; other
  artifacts matching `sdk-*` in the same workflow run would be committed too.
