# Development

Requires macOS 13+ and the Xcode command line tools. Graphviz (`brew install graphviz`) is only
needed to regenerate the diagrams; the GitHub CLI (`brew install gh`) only to publish releases.

## Build and install

```bash
./install.sh
```

Runs the self-tests, builds a universal (Apple silicon + Intel) `Cascade.app`, installs it to
`/Applications`, and launches it. On first run, turn on Cascade under System Settings → Privacy &
Security → Accessibility.

`./build.sh` alone produces `build/Cascade.app` and a distributable `build/Cascade-<version>.zip`.

Builds are ad-hoc signed with a designated requirement pinned to the bundle identifier, so the
Accessibility permission carries over between rebuilds. (A plain ad-hoc signature pins it to the
binary's hash instead, which makes macOS treat every build as a new app.)

## Tests

```bash
swift run CascadeSelfTest     # assertion checks for CascadeCore (no Xcode or XCTest needed)
swift build                   # debug build of everything
```

The layout and grouping logic lives in `CascadeCore`, which has no AppKit dependency, so it can be
checked without moving real windows. The app layer (Accessibility, menus, Settings) is tested by hand.

## App Facts label and diagrams

```bash
scripts/repo_report.py                # rebuild, then measure and regenerate everything
scripts/repo_report.py --skip-build   # reuse build/Cascade.app
```

Writes `docs/app-facts.svg` (the label), `docs/app-facts.json` (its raw numbers),
`docs/code-graph.svg` and `docs/cascade-flow.svg`. What it measures:

- **Code**: Swift lines per target, excluding blank and comment lines.
- **Tests**: runs `CascadeSelfTest`, and measures core line coverage with `llvm-cov`.
- **Size**: zip, app bundle, and each architecture slice.
- **Permissions**: scans the source for Accessibility, Screen Recording, keyboard monitoring and
  network APIs, and reads the signature and entitlements of the built app.
- **Performance**: samples the CPU time and memory of the running Cascade for 20 s, so keep it open.
  Then runs `Cascade --benchmark`, which times a full window scan and layout plan without moving
  anything.

## Releasing

```bash
./release.sh 2.1.0 [notes.md]
```

Bumps the version, builds, regenerates the label and diagrams, commits, tags, pushes, and publishes
a GitHub Release with the zip and its SHA-256 checksum. It stops if you have uncommitted changes or
the tag already exists. Without a notes file, GitHub writes the release notes. Test the build with
`./install.sh` first.
