# Contributing

Contributors follow the [Code of Conduct](CODE_OF_CONDUCT.md).

The source lives at [github.com/BTLabsUK/lepic-flutter](https://github.com/BTLabsUK/lepic-flutter).
Open issues and pull requests there.

## Before you start

- Read the [README](README.md) for what the package is and how it is built.
- Read the [usage guide](doc/guide.md) for what the API does.
- Most behaviour lives in [LEPIC](https://github.com/BTLabsUK/lepic), not here. A change to what a
  method does, or to its signature, is a change to LEPIC's `crates/lepic-ffi/src/api`, followed by
  a regeneration of the binding.

## Making a change

- Commits follow Conventional Commits and carry a DCO sign-off (`git commit -s`), as in LEPIC.
  [LEPIC's CONTRIBUTING.md](https://github.com/BTLabsUK/lepic/blob/main/CONTRIBUTING.md) gives the
  format, the types and the [DCO](https://developercertificate.org/).
- Every change passes these checks from the package root, after `tool/lepic.sh sync`:

  ```sh
  tool/lepic.sh check
  flutter analyze
  tool/lepic.sh test
  ```

  The `check` workflow runs the same three commands on every pull request. What each one needs
  installed is in the [README](README.md#requirements) and the
  [guide](doc/guide.md#testing).
- `lib/src/rust/` is generated and is never edited by hand. Change LEPIC's
  `crates/lepic-ffi/src/api`, then run `tool/lepic.sh generate` against the pinned LEPIC. The
  command writes the Rust half into the LEPIC checkout; commit that there, then move `lepic.rev`
  to that commit and commit `lib/src/rust/` here.
- `lepic.rev`, the LEPIC pin, moves only in a commit whose message says why.
- Each commit holds one logical change. Stage files by name.
- Doc comments in `lib/` that are not generated, and the pages in `doc/`, describe the code as it
  is. Check every name, default and error kind against the source.
