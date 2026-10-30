<div align="center">

# lepic-flutter

**The Flutter binding of LEPIC, the Epic Cash wallet core in Rust.**

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Flutter 3.47.5](https://img.shields.io/badge/flutter-3.47.5-02569B.svg)](pubspec.yaml)

[Quick start](#quick-start) · [Usage guide](doc/guide.md) ·
[LEPIC](https://gitlab.com/epic-cash-bt/lepic) · [Security](SECURITY.md)

Source: [GitLab](https://gitlab.com/epic-cash-bt/lepic-flutter) · Mirror: [GitHub](https://github.com/BTLabsUK/lepic-flutter)

</div>

`lepic` is a Dart package that lets a Flutter app run an Epic Cash wallet in its own process. It
wraps the FFI API of [LEPIC](https://gitlab.com/epic-cash-bt/lepic) (`crates/lepic-ffi`) through
[flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 2.13.0. Epic Cash Desktop
and Epic Cash Mobile use it.

The app creates one `LepicRuntime` and calls `EpicWallet` methods, which return Futures and
Streams. Every failure is a thrown `WalletError` with a stable numeric code. A build hook bundles
the native library into the app, so the app needs no Rust toolchain.

> **Status: beta.** It runs in production in Epic Cash Desktop and Epic Cash Mobile. The API may
> still change before 1.0.

## Requirements

To use the package in an app:

- Flutter 3.47.5 (Dart 3.13 or later; `pubspec.yaml` asks for `sdk: ^3.13.0`).
- The native library for each target, from `tool/lepic.sh build` (see below), or your own build of
  the pinned LEPIC.

To build the native library or change the bindings:

- Rust, at the version LEPIC pins in its `rust-toolchain.toml` (1.99.0 now). `rustup` installs it
  when you run a command inside the LEPIC checkout.
- `flutter_rust_bridge_codegen` 2.13.0: `cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked`.
- Android: the Android NDK and `cargo-ndk`. The libraries target Android API 24.
- iOS: Xcode, on macOS.
- Windows: Visual Studio Build Tools with the C++ workload.

## Build from scratch

LEPIC is cloned at the commit in `lepic.rev`, so the library always matches the generated Dart.
From the package root:

```sh
tool/lepic.sh sync                     # clone LEPIC at the pin into third_party/lepic
tool/lepic.sh build all                # every target this host can build
tool/lepic.sh build linux android      # or windows, or Rust target triples
```

Libraries land in `native/<rust triple>/` with a `SHA256SUMS` file. `hook/build.dart` checks that
file, and that the library was built from the pinned LEPIC, then bundles it as a Flutter native
asset for the target being built. See [Native libraries](doc/guide.md#native-libraries).

| Platform | Built on | What is tested |
|---|---|---|
| Linux x86_64 | Linux x86_64 | the host tests and the bridge check, before every merge |
| Android arm64, armv7, x86_64 | Linux or macOS, with NDK and `cargo-ndk` | an integration test on an Android emulator, run by hand |
| Windows x86_64 | Windows x86_64 | through Epic Cash Desktop's Windows builds |
| iOS device and simulator, arm64 | macOS with Xcode | through Epic Cash Mobile's iOS preview builds |
| macOS | none | the hook bundles no library yet |

Libraries are built with Tor. Set `WFE_TOR=0` to build without it
([guide](doc/guide.md#without-tor)).

## Quick start

Add the package from git (it is not on pub.dev):

```yaml
dependencies:
  lepic:
    git:
      url: https://gitlab.com/epic-cash-bt/lepic-flutter.git
```

Create a wallet:

```dart
import 'package:lepic/lepic.dart';

await RustLib.init();
final runtime = LepicRuntime(logLevel: LogLevel.info);

// Your adapter over the platform's secure storage; it implements SecretStore.
final store = lepicSecretStore(myFlutterSecureStorageAdapter);
final wallet = await EpicWallet.create(
  runtime: runtime,
  config: WalletConfig(
    dataDir: dir.path,
    chain: Chain.mainnet,
    nodeUrl: 'https://node.example:3413',
    epicboxDomain: 'relay.example.org', // the first [epicbox] server of the app's settings.toml
    epicboxPort: 443,
    onionRoutes: const [],
    tuning: appConfigTuning, // the [node], [epicbox], [http] and [tor] keys of app-config.toml
    offline: false, // true opens a cold wallet: no node or relay call (doc/guide.md)
  ),
  store: store,
  password: password,
);
```

The [usage guide](doc/guide.md) covers the rest: sending and receiving, invoices, errors, Tor,
and moving from an earlier binding.

## Project structure

| Path | Holds |
|---|---|
| `lepic.rev` | the LEPIC commit this package is generated from and built against |
| `lib/` | the public Dart API (`lepic.dart`) |
| `lib/src/rust/` | the generated Dart half of the bridge; never edited by hand |
| `hook/build.dart` | the build hook that bundles the native library into an app |
| `tool/` | `lepic.sh` (sync, build, test, generate, check) and `generate.dart` (codegen settings) |
| `test/` | host tests, run against a library with a scripted node |
| `emulator_test/` | an app with no UI that runs an integration test on an Android device |

The Rust half of the bridge, `frb_generated.rs`, lives in LEPIC. Both halves come from one codegen
run, and `tool/lepic.sh check` fails if either differs from what the pinned LEPIC generates.

## Testing

```sh
tool/lepic.sh check            # both bridge halves match the pinned LEPIC
flutter analyze
tool/lepic.sh test             # builds the scripted-node library, runs flutter test
tool/lepic.sh emulator-test    # on an attached Android device or emulator
```

`check`, `flutter analyze` and `test` run on our own machines before every merge; there is no
hosted CI, so run them yourself before you send a change. The
emulator test and the local-chain test are run by hand; see the
[guide](doc/guide.md#develop).

## Security

Secrets stay at the boundary: only secrets the user types or configures enter Rust, and only the
recovery phrase and the PIN key (for the app's secret store) leave it ([LEPIC ADR
0014](https://gitlab.com/epic-cash-bt/lepic/-/blob/main/docs/adr/0014-secrets-at-the-flutter-boundary.md)).
Please do not open public issues for vulnerabilities; [SECURITY.md](SECURITY.md) explains how to
report one privately.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first. This project follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Documentation

- Usage guide: [doc/guide.md](doc/guide.md)
- Developer documentation: https://docs.btlabs.uk/developers/lepic-flutter/
- Wiki: https://gitlab.com/epic-cash-bt/lepic-flutter/-/wikis/home
- Source: https://gitlab.com/epic-cash-bt/lepic-flutter (read-only mirror:
  https://github.com/BTLabsUK/lepic-flutter)

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).

<p align="center"><sub>Made by BT Labs</sub></p>
