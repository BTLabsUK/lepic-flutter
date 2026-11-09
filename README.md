<div align="center">

# lepic-flutter

**The Flutter binding of LEPIC, the Epic Cash wallet core in Rust.**

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Flutter 3.47.5](https://img.shields.io/badge/flutter-3.47.5-02569B.svg)](pubspec.yaml)

[Quick start](#quick-start) · [Usage guide](doc/guide.md) ·
[LEPIC](https://github.com/BTLabsUK/lepic) · [Security](SECURITY.md)

Source: [GitHub](https://github.com/BTLabsUK/lepic-flutter)

</div>

`lepic` is a Dart package that lets a Flutter app run an Epic Cash wallet in its own process. It
wraps the FFI API of [LEPIC](https://github.com/BTLabsUK/lepic) (`crates/lepic-ffi`) through
[flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) 2.13.0. BT Wallet, the app
that embeds LEPIC, uses it.

The app creates one `LepicRuntime` and calls `EpicWallet` methods, which return Futures and
Streams. A failed call throws a `WalletError` that carries a stable numeric code. A build hook
bundles the native library into the app, so the app needs no Rust toolchain.

The package is at version 0.1.0 and is not published on pub.dev.

## Requirements

To use the package in an app:

- Flutter 3.47.5. `pubspec.yaml` asks for Dart `^3.13.0` and Flutter `>=3.47.0`.
- A native library for each target, built with `tool/lepic.sh build` (below).

To build the native library or regenerate the bindings:

- Rust, at the version `rust-toolchain.toml` in LEPIC pins (1.99.0). `rustup` installs it when a
  command runs inside the LEPIC checkout.
- `flutter_rust_bridge_codegen` 2.13.0:
  `cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked`.
- Android: the Android NDK and `cargo-ndk`. The libraries target Android API 24.
- iOS: Xcode, on macOS.
- Windows: Visual Studio Build Tools with the C++ workload.

## Build from scratch

`lepic.rev` holds the LEPIC commit this package is generated from. `tool/lepic.sh` clones LEPIC
at that commit, so the library and the generated Dart always match. From the package root:

```sh
tool/lepic.sh sync                  # clone LEPIC at the pin into third_party/lepic
tool/lepic.sh build all             # every target this host can build
tool/lepic.sh build linux android   # or windows, or Rust target triples
```

Libraries land in `native/<rust triple>/` with a `SHA256SUMS` file. At app build time,
`hook/build.dart` checks that file and that the library was built from the pinned LEPIC, then
bundles the library as a Flutter native asset. See [Native libraries](doc/guide.md#native-libraries).

| Target | Built on | Command |
|---|---|---|
| Linux x86_64 | Linux | `tool/lepic.sh build linux` |
| Android arm64, armv7, x86_64 | Linux, Windows or macOS, with the NDK and `cargo-ndk` | `tool/lepic.sh build android` |
| Windows x86_64 | Windows | `tool/lepic.sh build windows` |
| iOS arm64, device and simulator | macOS with Xcode | `tool/lepic.sh build aarch64-apple-ios aarch64-apple-ios-sim` |

The hook bundles a library for Android, iOS, Linux and Windows targets. A macOS app build gets no
library from it.

Libraries are built with Tor. `WFE_TOR=0 tool/lepic.sh build all` builds without it
([guide](doc/guide.md#without-tor)).

## Quick start

Add the package from git:

```yaml
dependencies:
  lepic:
    git:
      url: https://github.com/BTLabsUK/lepic-flutter.git
```

Create a wallet:

```dart
import 'package:lepic/lepic.dart';

Future<EpicWallet> createWallet(String dir, String password) async {
  await RustLib.init();
  final runtime = LepicRuntime(logLevel: LogLevel.info);

  // mySecretStore implements SecretStore over the platform's secure storage.
  final store = lepicSecretStore(mySecretStore);
  return EpicWallet.create(
    runtime: runtime,
    config: WalletConfig(
      dataDir: dir, // an existing directory that only this wallet uses
      chain: Chain.mainnet,
      nodeUrl: 'https://node.example:3413',
      epicboxDomain: 'relay.example.org',
      epicboxPort: 443,
      onionRoutes: const [],
      tuning: appTuning, // a NetTuning built from the app's settings
      offline: false,
      torWanted: false,
      hostFeatures: 0,
      profile: 0,
      policy: const HostPolicy(),
    ),
    store: store,
    password: password,
  );
}
```

`EpicWallet.create` writes the encrypted vault into `store` and returns the open wallet.
`wallet.mnemonic(password: ...)` returns the recovery phrase for the backup screen.

The [usage guide](doc/guide.md) covers the rest: opening and restoring wallets, sending and
receiving, invoices, contacts, errors and Tor.

## Project structure

| Path | Holds |
|---|---|
| `lepic.rev` | the LEPIC commit this package is generated from and built against |
| `lib/` | the public Dart API (`lepic.dart`) and the test helpers (`testing.dart`) |
| `lib/src/rust/` | the generated Dart half of the bridge; never edited by hand |
| `hook/build.dart` | the build hook that bundles the native library into an app |
| `tool/` | `lepic.sh` (sync, build, test, generate, check) and `generate.dart` (codegen settings) |
| `test/` | host tests, run against a library with a scripted node and relay |
| `emulator_test/` | an app with no UI that runs an integration test on an Android device |
| `.github/workflows/check.yml` | the checks below, run on every pull request |

The Rust half of the bridge, `frb_generated.rs`, lives in LEPIC. Both halves come from one codegen
run, and `tool/lepic.sh check` fails if either differs from what the pinned LEPIC generates.

## Testing

```sh
tool/lepic.sh check            # both bridge halves match the pinned LEPIC
flutter analyze
tool/lepic.sh test             # builds the scripted-node library, runs flutter test
tool/lepic.sh emulator-test    # on an attached Android device or emulator
```

`check`, `flutter analyze` and `test` run in the `check` workflow on every pull request. The
emulator test and the local-chain test run by hand; see [Testing](doc/guide.md#testing).

## Security

Only secrets the user types or configures enter Rust. The recovery phrase and the PIN key (for the
app's secret store) are the only secrets that leave it
([LEPIC ADR 0014](https://github.com/BTLabsUK/lepic/blob/main/docs/adr/0014-secrets-at-the-flutter-boundary.md)).
[SECURITY.md](SECURITY.md) explains how to report a vulnerability privately.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. The project follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Documentation

- Usage guide: [doc/guide.md](doc/guide.md)
- LEPIC's FFI reference: [docs/ffi.md](https://github.com/BTLabsUK/lepic/blob/main/docs/ffi.md)
- Developer documentation: https://docs.btlabs.uk/developers/lepic-flutter/
- Source: https://github.com/BTLabsUK/lepic-flutter

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).

<p align="center"><sub>Made by BT Labs</sub></p>
