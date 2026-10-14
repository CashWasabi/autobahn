# Contributing

## Building and testing

Needs Zig 0.17.

```sh
zig build test                                      # every test, on real threads
zig build test -Doptimize=ReleaseFast               # races show up differently when optimised
zig fmt --check src examples build.zig build.zig.zon
zig build                                           # every example builds
zig build run_<name>                                # each example checks its own results
```

A change is ready when all of these pass.

## The code

- `std` only.
- One file: `src/root.zig`.
- Nothing is allocated.
  Everything sits where the caller puts it.
- Every public function has a test.
  Tests that involve lanes run on real threads.
  A test's name says what it checks.
- Every barrier keeps the rules in the README.
  Where a mistake would hang, add a cheap debug check that panics with a message.
- Use decl literals where the type is known.
  Write `var count: Atomic(u32) = .init(0);`, not `var count = Atomic(u32).init(0);`.
  An empty value is a declaration: `var queue: WorkQueue = .empty;`.
- Name counts, indices and sizes apart.
  `item_count` counts items.
  `lane_idx` is an index.
  A size is in bytes.
- Doc comments say what a call does and what the caller must do.
  Comments in code say why.
- A change users notice goes into the README.
  If it changes how something works, it also goes into the wiki in `docs/`.
- Markdown puts every sentence on its own line.
  Keep sentences short.

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/): `<type>: <what changed>`.
A scope is optional: `fix(queue): ...`.

| Type | For | Next release |
| --- | --- | --- |
| `fix` | a bug fix | patch |
| `feat` | a new feature | minor |
| `feat!` or `fix!` | a change that breaks callers | minor at 0.x, then major |
| `docs` | documentation only | patch, if released |
| `perf` | faster, same behaviour | patch |
| `refactor`, `test`, `build`, `ci`, `chore` | no change users see | none |

A `BREAKING CHANGE:` line in the body counts like `!`.

## Versions

Versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **Patch** (0.6.**x**): bug fixes, documentation and performance.
  Nothing you call changes.
- **Minor** (0.**x**.0): new features.
  While the major version is 0, a minor release may also break code.
  Each break is listed under **Changed** or **Removed** in the changelog.
- **Major** (**1**.0.0): when the API is stable.
  From then on only a major release breaks code.

The commits since the last tag decide the release.
Any breaking change means minor, or major after 1.0.
Otherwise any `feat` means minor.
Otherwise it is a patch.

## Changelog

Every change users notice gets a line in [CHANGELOG.md](CHANGELOG.md), in the same commit.
It goes under `## [Unreleased]`, below one of these headings:
**Added**, **Changed**, **Deprecated**, **Removed**, **Fixed**, **Security**.
The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Write the line for someone who uses the library.
Do not repeat the commit message.

## Releasing

Start from an up-to-date `main` with all checks passing.

1. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`.
   Add a new empty `## [Unreleased]` above it.
   Update the links at the bottom:
   ```
   [Unreleased]: https://github.com/CashWasabi/autobahn/compare/X.Y.Z...HEAD
   [X.Y.Z]: https://github.com/CashWasabi/autobahn/compare/<previous>...X.Y.Z
   ```
2. Set `.version = "X.Y.Z"` in `build.zig.zon`.
   Update the `zig fetch` line in the README's Install section.
3. Commit with `chore: release X.Y.Z`.
4. Tag it.
   The tag is annotated and has no `v`, so the README's `zig fetch ...#X.Y.Z` works:
   ```sh
   git tag -a X.Y.Z -m "autobahn X.Y.Z"
   git push origin main X.Y.Z
   ```
5. Wait for the `release` workflow on GitHub to pass.
   It runs on every version tag.
   It checks that the tag is on `main`.
   Then it checks formatting, runs the tests and runs the examples on Linux, macOS and Windows.
6. On GitHub, draft a release from the tag.
   Use that version's changelog section as the notes.

If the workflow fails, fix it in a new patch release.
Never move or delete a pushed tag.
Anyone who fetched it holds its hash.
