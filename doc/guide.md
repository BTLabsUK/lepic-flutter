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

## Wallet lifecycle

One `EpicWallet` handle is one open wallet. Four static methods produce a handle, and each takes
the runtime, a `WalletConfig` and the wallet's `AppSecretStore`.

| Method | Use |
|---|---|
| `EpicWallet.create` | makes a wallet; with `mnemonic` it restores that phrase |
| `EpicWallet.importWalletSeed` | makes a wallet from the text of an `epic-wallet` `wallet.seed` file and the password that file was written with (4,096 bytes at most) |
| `EpicWallet.open` | opens the wallet in `dataDir` with its password |
| `EpicWallet.openWithPin` | opens a wallet made for a PIN ([PIN wallets](#pin-wallets)) |

### Create and restore

```dart
final wallet = await EpicWallet.create(
  runtime: runtime,
  config: config,
  store: store,
  password: password,
);
final phrase = await wallet.mnemonic(password: password); // for the backup screen
```

Without `mnemonic`, `create` generates a seed. With `mnemonic` it restores that seed, and the app
then calls `scan` to find the wallet's outputs. `restoreFromHeight` sets the height that restore
scan starts from; it needs `mnemonic`, otherwise the call fails with `InvalidArgument`. Without
it the restore starts at genesis. Pass a height only when the phrase was first used above it:
outputs below the height are not found.

`create` fails with `InvalidArgument`, `WalletAlreadyExists` (the store holds a vault),
`InvalidMnemonic`, `ForeignWallet` (the directory holds another wallet's database), `WalletBusy`
(a wallet on that directory is open) and `SecretStore`.

`validateMnemonic(phrase:)` checks a phrase without a wallet. `walletExists(runtime:, store:)`
tells whether a store holds a vault. `walletFingerprint(mnemonic:, chain:)` and
`wallet.fingerprint()` return a 32-bit identifier of a phrase's wallet, to tell whether the app
already has it. The fingerprint identifies a wallet and does not prove a phrase: another phrase
can have the same value. Keep it out of logs.

### Open

```dart
final wallet = await EpicWallet.open(
  runtime: runtime,
  config: config,
  store: store,
  password: password,
);
```

`open` fails with `WrongPassword`, `WalletNotFound` (the store holds no vault), `ForeignWallet`,
`WalletBusy` and `DamagedDatabase`. On `DamagedDatabase` LEPIC has renamed the database to
`wallet.sqlite3.damaged-<unix seconds>`. Opening again builds a new database from the seed, and
`scan` without a start height then runs from genesis.

Every `open` attempt counts as a failure in the store (`lepic.pin-failures`) and may wait; a right
password clears the count ([PIN rules](#pin-rules)). Attempts of one runtime run one at a time.

### Scan, refresh and summary

| Call | Does |
|---|---|
| `scan(startHeight:, deleteUnconfirmed:)` | streams `ScanProgress` until an event with `finished`, which carries the result |
| `cancelScan()` | stops a running scan; the stream ends with `Cancelled` |
| `refresh()` | streams `RefreshProgress`: an event at 0 percent, then one at 100 with the `summary` |
| `summary(refresh:)` | returns the `WalletSummary`; without `refresh` it answers from the store |
| `restoreScanRequired()` | whether the wallet was rebuilt from its seed and no restore scan has completed |
| `transactions()`, `transaction(txId:)` | transaction records |
| `outputs()` | every output of the default account, spent ones included |
| `minimumConfirmations()`, `setMinimumConfirmations(count:)` | the confirmations an output needs to count as spendable; 6 until changed |

A scan stores every page of outputs as it goes, so a cancelled or failed scan leaves the wallet
consistent. The next scan with the same arguments resumes after the last stored page.

While `restoreScanRequired()` is true the wallet refuses new outputs: receiving, the change of a
send and invoices fail with `RestoreScanRequired`. A `scan` without `startHeight` starts where the
restore scan starts and ends the restore when it completes. A scan from a higher `startHeight`
leaves the restore pending.

`deleteUnconfirmed: true` also runs the repair of `epic-wallet scan --delete_unconfirmed`. It needs
`startHeight: null`, starts at the beginning of the chain, unlocks outputs locked by transactions
in progress that are unspent on chain, deletes outputs that are not on chain yet and cancels their
transactions, including sends waiting for an answer.

### Lock and delete

`wallet.lock()` stops the listener and any scan, wipes the root key and ends running calls with
`Cancelled`. Every later call on the handle fails with `Locked`. Open the wallet again on a new
handle. A call that failed with `Cancelled` at a lock may still have stored its effect: after a
lock, read the transactions again instead of taking the failure as the outcome. A send stored as
sent goes out again with its resend call, and one finalized is posted again with
`repostTransaction`.

`deleteWallet(runtime:, config:, store:)` deletes the database in `dataDir`, the vault in the
store, the PIN key and the failure count. It takes no password or PIN, so the app asks the user to
confirm first. It fails with `WalletBusy` while a wallet on that directory is open. Only the
recovery phrase brings the wallet back.

`resetPassword(runtime:, config:, store:, mnemonic:, newPassword:)` writes a new vault for a user
who forgot the password and keeps the database, its history and its outputs, so no scan follows.
Call it with the wallet closed. It proves the phrase against the database, not by fingerprint, and
fails with `InvalidMnemonic`, `PhraseMismatch` (the database belongs to another seed),
`ForeignWallet` (another chain), `WalletNotFound`, `WalletBusy` and `DamagedDatabase`. It removes
the PIN key and failure count, so a PIN wallet opens with `newPassword` afterwards.

### Encrypted database

The database is encrypted at rest. `storeAtRest()` returns a `StoreAtRest` with a `state`
(`encrypted`, `migratedNow` or `fellBackToPlain`), a `reason` and `rollbackSetAside`.
`retirePlainStore(olderThanDays:)` deletes the plain copies a migration leaves in `dataDir`,
`wallet.sqlite3.pre-encryption` and older `wallet.sqlite3.after-rollback-<unix>` files, and
returns a `RetiredPlainStore` with `deleted` and `kept`. It deletes nothing while the session runs
on the plain database. `runtime.storeMigrationProgress()` streams `StoreMigrationProgress` (a
`stage` of `copying`, `checking` or `finished`, with `done` and `total`) while a plain database is
copied.

### Other wallet data

| Call | Returns |
|---|---|
| `epicboxAddress()` | `<key>@<domain>[:port]`; fails with `Unsupported` when the configuration names no relay |
| `onionAddress()` | the wallet's `<56 characters>.onion` address |
| `epic1Address()` | the wallet's epic1 address |
| `sealAppData(payload:)`, `openAppData(file:)` | encrypt and decrypt an app file as a `WFEH` version 1 file, 32 MiB at most; only this wallet or one restored from the same phrase opens it |
| `nodeTip` and `nodeTipFor(config:)` | the tip and version of a node |

## Secret store, password and PIN

LEPIC keeps no secret on disk in the clear. The app gives each wallet a `SecretStore` over the
platform's secure storage, such as `flutter_secure_storage`:

```dart
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
```

`lepicSecretStore(store)` wraps it into the `AppSecretStore` every wallet call takes. An exception
in the app's store becomes a failed reply, and the LEPIC call fails with
`WalletErrorKind.secretStore`. Use one store per wallet: the keys have fixed names, and `write`
must have stored the value durably when it completes.

| Key | Holds |
|---|---|
| `lepic.vault` | the wallet's seed, encrypted under the password |
| `lepic.vault-next` | a replacement vault while a password change is under way |
| `lepic.pin-key` | the random key a sealed PIN password is bound to |
| `lepic.pin-key-pending` | the new PIN key while a PIN change awaits confirmation |
| `lepic.pin-failures` | the count of failed password or PIN attempts |

### Password wallets

`create`, `open`, `mnemonic(password:)` and `changePassword(currentPassword:, newPassword:)` take
the password as text. The vault is encrypted with Argon2id under a fresh salt. LEPIC sets no
minimum length for a password; the app does. `checkPassword(password:)` returns whether a password
opens the vault, for an action that asks again. A wrong password gives `false`, and the attempt is
counted like an `open`.

`changePassword` writes the new vault as `lepic.vault-next`, reads it back, then replaces
`lepic.vault`. If the app stops part way, the old or the new password opens the wallet and the
next `open` settles it. It fails with `Unsupported` for a PIN wallet.

### PIN wallets

A PIN wallet gives the app a short secret to ask for and keeps the wallet password inside LEPIC.
`createWithPin` generates the password, seals it under the PIN and returns a `PinWallet` with the
open `wallet` and the `sealedPassword` text. The sealed text is bound to the random key LEPIC
writes into the store as `lepic.pin-key`, so it opens only together with that store.

```dart
final created = await EpicWallet.createWithPin(
  runtime: runtime,
  config: config,
  store: store,
  pin: pin,
);
await appStorage.write('sealed', created.sealedPassword); // before anything else
final phrase = await created.wallet.mnemonicWithPin(
  pin: pin,
  sealedPassword: created.sealedPassword,
);
```

The app stores `sealedPassword` before it shows the phrase or receives funds. If the app stops
before it stored the text, the wallet cannot be opened by PIN: delete it with `deleteWallet` and
restore it from the phrase.

| Call | Does |
|---|---|
| `EpicWallet.createWithPin` | as `create`, with a generated and sealed password; also takes `mnemonic` and `restoreFromHeight` |
| `EpicWallet.importWalletSeedWithPin` | as `importWalletSeed`, with a generated and sealed password |
| `EpicWallet.openWithPin(pin:, sealedPassword:)` | opens the wallet; a wrong PIN gives `WrongPassword`, damaged text `InvalidArgument`, a store without the PIN key `SecretStore` |
| `wallet.mnemonicWithPin(pin:, sealedPassword:)` | returns the recovery phrase |
| `wallet.checkPin(pin:, sealedPassword:)` | returns nothing when the PIN is right and throws `WrongPassword` otherwise |
| `wallet.changePin(sealedPassword:, oldPin:, newPin:)` | returns the new sealed text; the change stays pending |
| `wallet.confirmPinChange(sealedPassword:)` | makes the change final once the app stored the new text |

`changePin` keeps the new key as `lepic.pin-key-pending` next to `lepic.pin-key`. Until
`confirmPinChange`, the old PIN with the old text and the new PIN with the new text both open the
wallet. Store the new text first, then confirm. If the app stops before it stored the text, the
old pair still opens.

### PIN rules

`PinSettings` holds the rules of a runtime. Create the runtime with
`LepicRuntime.withPinSettings(logLevel:, pin:)` to change them; `LepicRuntime(logLevel:)` uses
`await PinSettings.default_()`.

| Field | Default | Meaning |
|---|---|---|
| `minLen` | 6 | shortest PIN `createWithPin` and `changePin` accept (`InvalidArgument` otherwise) |
| `freeFailures` | 3 | failed attempts that never wait |
| `firstDelayS` | 30 | wait before an attempt after the free failures |
| `maxDelayS` | 3,600 | the wait doubles after each further failure up to this |

Every attempt to open, check or change by password or PIN is counted in the store as
`lepic.pin-failures` until a right one clears the count. The count lives in the store, so
restarting the app does not reset it.

## Events

`wallet.events()` streams `WalletEvent` records until the wallet is dropped. Each has a `kind`
(`WalletEventKind`) and the fields that kind sets, such as `txId`, `slateId`, `amount`,
`contactId`. Subscribe once, right after opening.

| Kind | Meaning |
|---|---|
| `session` | the session state changed (`session`) |
| `balance` | the balance of an account after a refresh |
| `transaction` | a transaction moved from `from` to `to` |
| `sync_` | scan progress (`height`, `targetHeight`) |
| `transport` | a transport's connection changed |
| `missed` | the stream fell behind and `missed` events were dropped; refresh to catch up |
| `selfSend` | a split or consolidation was stored and finalized |
| `invoiceReceived`, `invoiceFromContact` | an invoice waits to be paid or declined |
| `invoiceFinalized`, `invoicePosted`, `invoiceExpired`, `invoiceDeclined`, `invoiceWithdrawn`, `invoiceBounced` | the course of an invoice ([Invoices](#invoices)) |
| `withdrawalFromContact`, `sealedReceived` | a contact's payment arrived and was received |
| `contactPaymentFinalized`, `paymentDeclined`, `paymentCancelled`, `notPosted` | the course of a payment this wallet sent |
| `receiveSuperseded`, `paymentPosted` | news about a payment this wallet received |
| `pairingRequested`, `pairingReplied`, `pairingConfirmed`, `pairingFailed` | pairing steps ([Contacts and pairing](#contacts-and-pairing)) |
| `contactUpdated`, `contactKeysRestored`, `contactKeysChanged`, `contactRelayMoveRequested`, `contactUnpaired`, `contactPayload`, `contactPayloadsParked` | changes to a contact |
| `homeRelayUnreachable`, `outboxDelivered`, `outboxStuck` | delivery to contact mailboxes |
| `inPersonAnswer` | an answer to an in-person code was taken |
| `unknownSlate`, `noticeUnmatched`, `sealedUnopenable` | advisory events |

The doc comment of each kind in `lib/src/rust/api/types.dart` lists the fields it sets.

Advisory events (`unknownSlate`, `noticeUnmatched`, `sealedUnopenable`) report messages that
nothing has verified: anyone who knows the wallet's address can cause them. Show them as
information and never act on them or show their sender as trusted.
