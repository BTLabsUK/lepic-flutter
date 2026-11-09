# Security policy

## Reporting a vulnerability

Do not open a public issue and do not describe a vulnerability in the public repository,
[BTLabsUK/lepic-flutter](https://github.com/BTLabsUK/lepic-flutter). Email **support@btlabs.uk**.

Include the affected version or commit, what an attacker controls, what happens, and the smallest
reproduction you have.

## Scope

In scope is this package's boundary with the native library:

- Secrets crossing the FFI: anything that leaks a key, phrase, password or PIN into Dart, into
  logs or into the platform.
- How the native library is loaded and verified in `hook/build.dart`: the checksum file, the
  pinned-source check and the feature check.

Issues in the wallet engine (transactions, keys, storage, parsing of untrusted input) belong to
LEPIC: see [LEPIC's SECURITY.md](https://github.com/BTLabsUK/lepic/blob/main/SECURITY.md). Issues
in the Epic node, the reference wallet or the Epicbox relay belong to those projects.

## Supported versions

The package is at version 0.1.0 and has no stable release yet. Only the latest commit on `main`
receives fixes.
