## What and why

<!-- What the change does and why. The diff shows how. -->

## How it was checked

<!-- The commands you ran and what they showed. -->

```sh
tool/lepic.sh check
flutter analyze
tool/lepic.sh test
```

## Checklist

- [ ] One logical change per commit, files staged by name, commits signed off (`git commit -s`).
- [ ] `lib/src/rust/` is untouched, or regenerated with `tool/lepic.sh generate`.
- [ ] No secrets, local paths, build output or private material.
