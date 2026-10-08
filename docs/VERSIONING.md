# Versioning: one source of truth

Follows the owner's standard (Kerf's `docs/VERSIONING.md`).

## Rule
**`build.zig.zon` `.version` (repo root) is the only place the version is written.** It must be valid semver.
Everything else derives from it:

```
build.zig.zon .version --> build.zig (comptime @import) --> build_options.version --> `webzocket.version`
                     \--> git tag "v<version>" (release CI refuses a mismatch)
```

- No version literals in source, docs, CI or badges. Code and tests read `webzocket.version`.
- No git at configure time, so tarball and package-fetch builds report the right version.
- On `master` the manifest holds the version of the latest release. To tell a dev build apart, pass
  `-Dversion-meta=<str>` (e.g. `-Dversion-meta=g$(git rev-parse --short HEAD)`); it is appended as `+<str>`.
- Never embed the version in deterministic outputs (goldens, exports). Report it only in `version` APIs, UI and User-Agent strings.
- Minimum-Zig-version mentions (`.minimum_zig_version`, `ZIG_VERSION`) are not package versions.

## Releasing
Releases are explicit; nothing auto-tags and PRs need no version bump.

```sh
tools/release.sh <semver>     # bumps .version, commits "release: v<semver>", tags v<semver>, pushes
```

The `release` workflow (on `v*` tags) first fails unless `v` + the zon version equals the tag, then runs the tests
and creates the GitHub release with generated notes.
