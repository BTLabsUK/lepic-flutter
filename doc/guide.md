# lepic-flutter usage guide

This guide covers how a Flutter app uses the `lepic` package: building and bundling the native
library, starting the runtime, creating and opening a wallet, keeping its secrets in the app's
storage, sending and receiving by each method, contacts, errors and tests. The package wraps
[LEPIC](https://github.com/BTLabsUK/lepic), the Rust wallet core, through
[flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 2.13.0. The
[README](../README.md) has the short version.

Every call is an `async` method that returns a Future or a Stream. A failed call throws a
[`WalletError`](#errors). LEPIC's own documents describe the behaviour behind each call: the
[FFI reference](https://github.com/BTLabsUK/lepic/blob/main/docs/ffi.md), the
[protocols](https://github.com/BTLabsUK/lepic/blob/main/docs/protocols/README.md) and the
[configuration](https://github.com/BTLabsUK/lepic/blob/main/docs/configuration.md). The Dart doc
comments in `lib/src/rust/api/` are generated from the Rust doc comments and list the errors of
every call.

## Contents

- [Package layout](#package-layout)
- [Build and generate](#build-and-generate)
- [Native libraries](#native-libraries)
- [The runtime](#the-runtime)
- [Configuration](#configuration)
- [Wallet lifecycle](#wallet-lifecycle)
- [Secret store, password and PIN](#secret-store-password-and-pin)
- [Events](#events)
- [Sending and receiving](#sending-and-receiving)
- [Listeners and Tor](#listeners-and-tor)
- [Invoices](#invoices)
- [Contacts and pairing](#contacts-and-pairing)
- [QR codes and in-person transfers](#qr-codes-and-in-person-transfers)
- [epic1 links](#epic1-links)
- [Offline sessions](#offline-sessions)
- [Secrets that cross the boundary](#secrets-that-cross-the-boundary)
- [Errors](#errors)
- [Testing](#testing)

## Package layout

`import 'package:lepic/lepic.dart';` exports the public API:

| Item | Source |
|---|---|
| `EpicWallet`, `LepicRuntime`, the config, result and event types | `lib/src/rust/api/*.dart`, generated |
| `SecretStore`, `lepicSecretStore` | `lib/lepic.dart`, hand-written |
| `RustLib` | `lib/src/rust/frb_generated.dart`, generated |

`import 'package:lepic/testing.dart';` exports the scripted node and relay for tests
([Testing](#testing)). It needs a library built with LEPIC's `mock` feature and is not for apps.

`lib/lepic.dart` does not export `lib/src/rust/api/in_person.dart` or
`lib/src/rust/api/contact.dart`. The top-level functions `inPersonQrParts`, `inPersonQrRead` and
`sealedFileExtension` live in those two files.

The Rust half of the bridge, `frb_generated.rs`, lives in LEPIC. One codegen run writes both
halves, so the Dart code and the native library must come from the same LEPIC commit. `lepic.rev`
holds that commit.

## Build and generate

`tool/lepic.sh` is the one entry point. It clones LEPIC at the commit in `lepic.rev` into
`third_party/lepic` and runs every build and check there.

| Command | Does |
|---|---|
| `sync` | clones or updates LEPIC at the pin |
| `build linux`, `android`, `windows`, `all` or Rust target triples | builds release libraries into `native/<triple>/`; `all` builds every target the host can |
| `test [flutter test args]` | builds the mock library into `test_native/`, then runs `flutter test` |
| `emulator-test [serial]` | runs `emulator_test/` on an attached Android device or emulator |
| `generate` | runs flutter_rust_bridge codegen from LEPIC's `crates/lepic-ffi/src/api`; writes the Dart half into `lib/src/rust/` and the Rust half and `bridge.sha256` into the LEPIC checkout |
| `check` | fails when either half of the bridge differs from what the pinned LEPIC generates |
| `lib` | prints the path of the Linux library, `native/x86_64-unknown-linux-gnu/liblepic_ffi.so` |

Environment variables:

| Variable | Effect |
|---|---|
| `WFE_TOR` | `0`, `false` or `off` builds without Tor |
| `LEPIC_DIR` | uses this LEPIC checkout instead of `third_party/lepic` |
| `LEPIC_REPO` | clones LEPIC from this URL |

`build`, `test` and `check` need a clean LEPIC checkout at the pin. `generate` accepts any commit.
`bridge.sha256` in LEPIC's `crates/lepic-ffi` records what the two halves were generated from, and
`tool/generate.dart` holds the codegen settings. The same flutter_rust_bridge version must appear
in `pubspec.yaml`, in LEPIC's `Cargo.lock` and in the `flutter_rust_bridge_codegen` binary
(2.13.0); `generate` stops when they differ.

To use another LEPIC commit whose Rust half is committed, write it into `lepic.rev`, run
`tool/lepic.sh sync` and `tool/lepic.sh generate`, commit the regenerated `lib/src/rust/`, and
rebuild the libraries.

## Native libraries

The package ships no binary. `tool/lepic.sh build` compiles `lepic-ffi` into
`native/<rust target>/` and writes three files next to each library:

| File | Holds |
|---|---|
| `SHA256SUMS` | the SHA-256 of the library, in `sha256sum` format |
| `SOURCE` | `lepic <commit>` and `tree clean` |
| `FEATURES` | one line per `lepic-ffi` feature the library was built with, such as `tor` |

At app build time `hook/build.dart` finds the library for the target, checks it and registers it
as a native asset named `src/rust/frb_generated.io.dart`, loaded as a bundled dynamic library.
The hook throws when:

- the library or `SHA256SUMS` is missing, or `SHA256SUMS` does not record exactly one hash for the
  library, or the hash differs;
- `SOURCE` lacks the line `lepic <commit>` for the commit in `lepic.rev`, or lacks `tree clean`;
- the `tor` user define does not match `FEATURES` (below);
- the app asks for a static link mode.

A missing `FEATURES` file counts as a library with Tor.

| Target | Library path under `native/` |
|---|---|
| `aarch64-linux-android` | `aarch64-linux-android/liblepic_ffi.so` |
| `armv7-linux-androideabi` | `armv7-linux-androideabi/liblepic_ffi.so` |
| `x86_64-linux-android` | `x86_64-linux-android/liblepic_ffi.so` |
| `aarch64-apple-ios`, `aarch64-apple-ios-sim` | `<triple>/liblepic_ffi.dylib` |
| `x86_64-unknown-linux-gnu` | `x86_64-unknown-linux-gnu/liblepic_ffi.so` |
| `x86_64-pc-windows-msvc` | `x86_64-pc-windows-msvc/lepic_ffi.dll` |

macOS builds get no asset. The Android libraries link against API 24: an app with a lower
`minSdk` fails the hook with `UnsupportedError` ("raise minSdk").

### User defines

An app sets the hook's options in its own `pubspec.yaml`. Dart reads user defines from the
pubspec of the root package only.

```yaml
hooks:
  user_defines:
    lepic:
      tor: true
      native_dir: third_party/lepic-natives
```

| Define | Meaning |
|---|---|
| `native_dir` | directory that holds the `<triple>/` folders; a relative path resolves against the pubspec of the package that defines it; default is `native/` in the `lepic` package |
| `tor` | `true` or `false`; the hook fails unless the library was built with (true) or without (false) Tor; unset accepts either; any other value fails the build |

### Without Tor

A library built with `WFE_TOR=0 tool/lepic.sh build all` leaves out the Tor client. The API is the
same, so one generated binding serves both builds. Calls that need Tor behave as follows:

| Call | Without Tor |
|---|---|
| `startTor`, `refreshTor`, `onionAddress`, `sendTor`, `resendTor` | fail with `WalletErrorKind.unsupported` |
| `torStatus()` | reports `TorStatusKind.off` |
| `validateOnionAddress` | returns `false` for every address |
| `onionRoutes` in `WalletConfig` and `setOnionRoutes` | keep no route |
| `torWanted` | ignored |
| `nodeTip` through a SOCKS route | fails with `unsupported` |

To bundle a library without Tor, build it with `WFE_TOR=0` and set `tor: false` in the user
defines, so a library with Tor cannot be bundled by mistake.

## The runtime

Call `RustLib.init()` once, before any other call. Then create one `LepicRuntime` for the
process. A runtime serves any number of wallets and holds the log stream and the PIN rules.

```dart
await RustLib.init();
final runtime = LepicRuntime(logLevel: LogLevel.info);
```

`LepicRuntime.withPinSettings(logLevel:, pin:)` starts a runtime with PIN rules of the app's
choice ([PIN rules](#pin-rules)).

| Method | Does |
|---|---|
| `logs()` | streams `LogEntry` records at the runtime's level and above; a new call replaces the earlier stream |
| `stopLogs()` | ends the stream |
| `logMessage(level:, tag:, message:)` | writes one line from the app under the target `dart`; `tag` keeps ASCII letters, digits and `_` (32 at most), `message` its first 1,024 bytes |
| `openLogRing(dir:, maxBytes:)` | keeps redacted records in a ring of files in `dir`; `maxBytes` is 4 KiB to 16 MiB; `dir` should hold nothing else |
| `storeMigrationProgress()` | streams `StoreMigrationProgress` while a plain database is copied into an encrypted one |

`RustLib.dispose()` is a static method; the bridge is also disposed when the app stops. Records on
the stream and in the ring are redacted. LEPIC's
[logging page](https://github.com/BTLabsUK/lepic/blob/main/docs/logging.md) lists the rules. Never
pass a secret to `logMessage`.

## Configuration

`WalletConfig` carries everything a wallet reads when it is created, restored or opened.

| Field | Type | Meaning |
|---|---|---|
| `dataDir` | `String` | directory that holds the wallet database `wallet.sqlite3`; it must exist and only this wallet may use it |
| `chain` | `Chain` | the network, such as `Chain.mainnet` |
| `nodeUrl` | `String` | the Epic node's foreign API URL |
| `nodeApiSecret` | `String?` | the node's API secret, when it needs one |
| `epicboxDomain` | `String` | the Epicbox relay's domain; empty turns Epicbox off |
| `epicboxPort` | `int` | the relay's port |
| `onionRoutes` | `List<OnionRoute>` | hosts known to be onion services (256 at most) |
| `tuning` | `NetTuning` | timeouts, retries and limits for the node, relay, HTTP and Tor |
| `offline` | `bool` | an [offline session](#offline-sessions) |
| `torWanted` | `bool` | the app will start Tor this session |
| `hostFeatures` | `int` | feature bits the app claims to other LEPIC wallets; only bits 4 and 5 are kept |
| `profile` | `int` | the app's profile bits, sent to paired contacts in bits 16 to 31 of the pairing features |
| `domain` | `String?` | a domain the wallet claims to its contacts, for a service wallet; `null` for an app wallet |
| `policy` | `HostPolicy` | limits and defaults the app chooses |

An Epicbox relay on a loopback host (`localhost` or `127.x.x.x`) is reached over a plain
websocket. Any other host is reached over TLS. `torWanted` is ignored on iOS and in a build
without Tor.

`NetTuning` holds four groups, `node`, `epicbox`, `http` and `tor`. Every field is required:
LEPIC has no defaults of its own, and a zero or a minimum above its maximum fails the call with
`InvalidArgument`. `test/shipped_tuning.dart` is a complete example.

`HostPolicy` holds the app's limits and defaults. Every field is nullable, and `const
HostPolicy()` leaves all of them to LEPIC, which applies the defaults below.
`await HostPolicy.default_()` returns a policy with those values filled in.

| Field | Default | Range |
|---|---|---|
| `defaultStrategy` | `SelectionStrategy.smallest` | |
| `sendTtlBlocks` | 1,440 | |
| `invoiceTtlBlocks` | 1,440 | |
| `maxChangeOutputs` | 10 | |
| `maxExcludedOutputs` | 500 | |
| `invoiceExpiryDefaultS` | 86,400 | |
| `invoiceExpiryMaxS` | 172,800 | |
| `maxInvoiceTtlLeadBlocks` | 2,880 | 1 to 525,600 |
| `maxOpenReceiptsPerSender` | 10 | |
| `maxOpenReceipts` | 100 | |
| `defaultMinimumConfirmations` | 6 | |
| `contactCheckAnswersPerHour` | 1 | 1 to 24 |
| `contactCheckAnswersPerDay` | 3 | 1 to 24 |
| `contactHoldAttempts` | 3 | 1 to 10 |
| `contactHoldPatienceS` | 180 | 1 to 86,400 |
| `refuseUnsolicitedPayments` | `false` | |
| `refuseUnsolicitedInvoices` | `false` | |
| `listenerHeldRounds` | none | 1 to 64 |
| `quarantineMaxBytes` | none | 1 to 67,108,864 |
| `earlyNoticeMaxCount` | none | 1 to 10,000 |
| `earlyNoticeMaxAgeS` | none | 1 to 2,592,000 |
| `publishPreviousOnion` | `false` | |

`earlyNoticeMaxCount` and `earlyNoticeMaxAgeS` are set together or not at all; one without the
other fails the call with `InvalidArgument`.

`setServers(config:)` moves an open wallet to another node or relay. The new `WalletConfig` must
keep the wallet's `dataDir`, `chain` and `offline` value, and cannot switch Epicbox on or off.

`nodeTip(runtime:, config:, route:)` asks a node for its tip and version without a wallet; the
route says whether the request goes directly or through a SOCKS5 proxy on a loopback address.
