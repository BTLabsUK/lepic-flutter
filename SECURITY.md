# Security policy

## Reporting a vulnerability

Do not open a public issue, and do not report a vulnerability in the public repository,
[BTLabsUK/lepic-flutter](https://github.com/BTLabsUK/lepic-flutter). Email **support@btlabs.uk**.

Include the affected version or commit, what an attacker controls, what happens, and the smallest
reproduction you have.

## Scope

In scope: this package's boundary with the native library. That means secrets crossing the FFI
(anything that leaks a key, phrase, password or PIN into Dart, logs or the platform), and how the
native library is loaded and verified in `hook/build.dart` (the checksum, the pinned-source and
feature checks).

Issues in the wallet engine itself (transactions, keys, storage, parsing of untrusted input) belong
to LEPIC: see [LEPIC's SECURITY.md](https://github.com/BTLabsUK/lepic/blob/main/SECURITY.md).
Issues in the Epic Cash node, the reference wallet or the Epicbox relay belong to those projects.

## Supported versions

This package is pre-1.0. Only the latest release receives fixes.
