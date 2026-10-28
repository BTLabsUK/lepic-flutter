# Contributing

Thanks for helping. Contributors follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Making a change

- Commits follow Conventional Commits with a DCO sign-off (`git commit -s`), the same as LEPIC;
  see [LEPIC's CONTRIBUTING.md](https://gitlab.com/btlabs/lepic/-/blob/main/CONTRIBUTING.md)
  for the format, the types and the [DCO](https://developercertificate.org/).
- Every change passes, from the package root after `tool/lepic.sh sync`:

  ```sh
  tool/lepic.sh check
  flutter analyze
  tool/lepic.sh test
  ```

  [doc/guide.md](doc/guide.md#develop) explains the tools and what you need installed.
- Never edit `lib/src/rust/` by hand. It is generated: change LEPIC's `crates/lepic-ffi/src/api`
  and run `tool/lepic.sh generate` against the pinned LEPIC.
- `lepic.rev` (the LEPIC pin) moves only in a commit whose message says why.
- Keep one logical change per commit, and stage files by name.
