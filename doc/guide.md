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

## Sending and receiving

Amounts are `BigInt` base units. A send takes `minimumConfirmations`: pass the value of
`wallet.minimumConfirmations()` so the send spends what the balance calls spendable.

### Choosing inputs and change

`SendOptions` chooses a send's inputs and change. A call given `null` uses `Smallest` with one
change output.

| Field | Meaning |
|---|---|
| `strategy` | `SelectionStrategy.smallest`: the fewest of the smallest outputs that cover amount and fee. `all`: every spendable output, up to 500 |
| `changeOutputs` | 1 to 10 outputs for the change, equal parts with the remainder on the last; each adds to the fee |
| `excludeOutputs` | up to 500 output commitments (66 hex characters) the send must not take; unknown ones are ignored |

`estimateFee(amount:, minimumConfirmations:, options:)` returns a `FeeEstimate` (`fee`,
`inputCount`, `change`, `locked`, `changeOutputs`) and locks nothing. A send at the same chain tip,
with the same options and no output changed in between, charges that fee. `estimateMax` returns
the largest amount a send can pay; use it with `SelectionStrategy.all` to send everything.
`estimateSendToSelf` does the same for [`sendToSelf`](#splitting-and-merging-outputs).

### Methods

| Method | Call | The other wallet's answer |
|---|---|---|
| Epicbox | `sendEpicbox(amount:, minimumConfirmations:, address:, message:, options:)` | the listener or `drainEpicbox` finalizes and posts it |
| HTTP | `sendHttp(..., url:, allowPlainHttp:)` | `sendHttp` waits for it, finalizes and posts |
| Tor | `sendTor(..., onion:)` | `sendTor` waits for it, finalizes and posts |
| Slate text | `createSendSlate` then `finalizeAndPost` | the app carries the slate and the answer |
| Slate file | `sendFile(..., path:)` then `finalizeFile` | the app carries the file and the answer |
| In person | [`inPersonSend`](#qr-codes-and-in-person-transfers) | the app carries the code and the answer |
| Contact | [`contactSend`](#contacts-and-pairing) | through the contact's mailbox |

`address` of `sendEpicbox` is `<key>@<relay>[:port]`; an address `validate_epicbox_address`
refuses, such as a key without `@<relay>`, fails with `InvalidArgument` and stores nothing.
`message` goes to the recipient signed with the slate and is cut to its first 256 bytes.

```dart
final sent = await wallet.sendEpicbox(
  amount: BigInt.from(1500000000),
  minimumConfirmations: await wallet.minimumConfirmations(),
  address: 'es1qexample...@relay.example.org',
);
// sent.txId, sent.slateId, sent.fee; sent.format is SlateWire.legacy or SlateWire.native
```

A send is stored and its inputs are locked before it goes out. When delivery fails, the send stays
stored as sent:

| Failure | Deliver again with |
|---|---|
| `sendEpicbox` fails with `TransportFailed`, or `TransactionDetails.undelivered` is set | `resendEpicbox(txId:)` |
| `sendHttp` or `sendTor` fails with `TransportFailed` | `resendHttp(txId:, url:, allowPlainHttp:)` or `resendTor(txId:, onion:)`, to any address |
| the answer was received but the node refused the transaction (`NotPosted`, or `posted` false) | `repostTransaction(txId:)` |
| the send should not go ahead | `cancelTransaction(txId:)` |

`cancelTransaction` fails with `OnChain` or `InPool` when the node holds the finalized transaction.
`releaseTransaction(txId:)` frees a finalized or posted send the network never took, once
`TransactionDetails.releasable` says so; a node that mines it later spends the inputs after all.

### HTTP

`sendHttp` posts to `http(s)://host[:port][/path]`. A missing port is 3415 for `http` and 443 for
`https`. Plain `http` to any host but this device needs `allowPlainHttp: true`; set it only after
the user agreed that the slate travels unencrypted, or the call fails with `PlainHttpNotAllowed`.
Over Tor, see [Listeners and Tor](#listeners-and-tor).

`HttpSentTx` has `posted` (false when the node refused the transaction), `dialect`
(`SendDialect.native` or `legacy`) and `format`.

### Native slates

With `setNativeDirect(enabled: true)` a send over HTTP or Tor to a wallet that advertises a native
endpoint is sealed to that wallet's key
([ADR 0052](https://github.com/BTLabsUK/lepic/blob/main/docs/adr/0052-native-direct-endpoint.md)).
Every other wallet gets the slate as every Epic wallet takes it. The setting is stored in the
wallet's directory and applies when the wallet next opens; `nativeDirectInUse()` says what the
session does. `sendHttpDialect(..., legacy: true)`, `sendTorDialect` and the matching resend calls
send the legacy form whatever the other wallet advertises.

After a native exchange succeeds, the wallet pins the key for the URL's origin. `peerPins()` lists
the pins (`PeerPinView`: `origin`, `sealKey`, `firstSeenMs`, `lastSeenMs`). A send to a pinned
origin fails when the wallet there stops advertising (`PinnedNoAdvert`), advertises another key
(`PinChanged`) or cannot be asked (`PeerProbeFailed`); `WalletError.origin` names the origin. After
the user confirmed that the wallet changed its key, `forgetPeerPin(origin:)` drops the pin. A wallet
advertising a native endpoint on `localhost` or an address of the device fails with `ThisComputer`;
ask for the legacy dialect.

### Receiving

`receiveSlate(slateJson:)` and `receiveFile(path:)` sign an incoming send and return the answer for
the sender in `ReceivedSlate.json`. `receiveFile` also writes it to `<path>.response`. The same
slate again returns the stored answer with `repeated` set and the first call's `txId`; show it as
already answered, not as a second payment. A wallet whose restore scan is pending refuses with
`RestoreScanRequired`.

Payments over Epicbox, HTTP and Tor arrive through the [listeners](#listeners-and-tor) or
`drainEpicbox()`, which connects once, handles every pending message and disconnects. It returns an
`InboxReport` with counts of what was received, finalized, repeated, rejected, held on the relay,
noticed, bounced, dropped and buffered.

### Finishing a send

`finalizeAndPost(slateJson:)` takes the recipient's answer to a send, or the payer's answer to an
invoice this wallet issued, and posts the transaction. Finalizing the same answer again returns the
stored result. `FinalizedTx.posted` is false in an [offline session](#offline-sessions), where
nothing goes to the node.

### Splitting and merging outputs

`sendToSelf(request:, minimumConfirmations:)` spends outputs into outputs of the same wallet as a
normal network transaction, never through the Epicbox address. `SelfSendRequest` combines `inputs`
(`SelfInputs.all`, `smallest`, `named`) with `outputs` (`SelfOutputs.count` or `amounts`), 1 to 10
outputs in all. A split into `n` is `all` with `count` `n`; a merge is `all` with `count` 1. It
appears as two transactions over transport `self`. `SelfSentTx` holds both transaction ids.

### Inspecting slates

`inspectSlate` reads a slate's text and describes it without storing anything. `finishedPayment`
returns the final slate of a finalized, posted or confirmed transaction as legacy V3 JSON, which
`epic-wallet post -i` reads, to post from another device. `encodeUrSlate` and `decodeUrSlate`
convert a slate to and from the parts of an animated QR code
([QR codes](#qr-codes-and-in-person-transfers)).

## Listeners and Tor

A wallet receives only while a listener runs. The app starts the ones it wants after opening the
wallet and keeps their streams subscribed.

| Listener | Start | Receives | Stream |
|---|---|---|---|
| Epicbox | `startListener()` | payments and answers through the configured relay | `ListenerEvent` |
| HTTP | `startHttpListener(exposure:, port:, coinbase:)` | payments at `http://<host>:<port>` | `HttpListenerEvent` |
| Tor | `startTor(torBinary:, libDir:, publishOnion:)` | payments at the wallet's onion | `TorEvent` |

Each wallet runs at most one of each; a second call returns a stream that ends at once. On a locked
wallet the stream ends with `Locked` as its error.

### Epicbox listener

`startListener()` subscribes at the relay named in the `WalletConfig`, answers payments, and
finalizes and posts answers to this wallet's sends. Its last event is `Stopped`. A relay that
cannot be reached gives `Disconnected` events with `reason` and `retryInMs`, and the listener
retries with backoff. Without a relay in the configuration the stream fails with `Unsupported`.
`stopListener()` ends it; `listenerRunning()` tells whether it runs.

| `ListenerEventKind` | Meaning |
|---|---|
| `connected`, `disconnected` | the relay connection |
| `received`, `repeated` | a payment was signed and answered, or came again and was answered with the stored reply |
| `finalized` | an answer to one of this wallet's sends was finalized and posted |
| `invoiceBounced` | a payer sent an invoice back unpaid, as a stock `epic-wallet` does; cancel it with `cancelTransaction` |
| `error`, `stopped` | the listener failed (`stopped` follows) or ended |

### HTTP listener

`startHttpListener` serves the foreign API on `port`; `epic-wallet` listens on 3415. Port 0 lets the
system pick one, which `Started` and `httpListenerStatus()` report.

| `HttpExposure` | Reachable from |
|---|---|
| `localOnly` | this device, on `127.0.0.1` |
| `internet` | every network interface, on `0.0.0.0`; anyone who can reach the port can send the wallet payments |

`HttpCoinbase` (`off`, `localOnly`, `remote`) sets who the listener builds block rewards for, so a
mining node pays them to the wallet ([LEPIC HTTP page](https://github.com/BTLabsUK/lepic/blob/main/docs/protocols/http.md)).
The first event is `started`, `portInUse` or `bindFailed`. Events carry `txId`, `amount` and
`repeated` for `received`, and a `refusal` (`rejected` for good, `unavailable` for now) for
`refused`. They carry nothing about the sender. `stopHttpListener()` ends it.

### Tor

`startTor` starts the Tor binary at `torBinary` and, with `publishOnion`, publishes the wallet's
onion service behind a listener of its own. The onion is the same on every start. Tor keeps its
files in `tor` inside the data directory. Native builds with Tor and the Tor binary are described in
[Native libraries](#native-libraries); a build without Tor is in [Without Tor](#without-tor). iOS
starts nothing: the stream gets `Failed` with `Missing`, then `Stopped`.

```dart
wallet.expectTor(); // before startListener, so the relay waits for tor
wallet.startTor(torBinary: torPath, libDir: torLibDir, publishOnion: true).listen((e) {
  if (e.kind == TorEventKind.ready) showOnion(e.onion!);
});
```

| `TorEventKind` | Meaning |
|---|---|
| `starting` | connecting to the Tor network; `progress` 0 to 100 |
| `bootstrapped` | connected; sends to onions work; `socksPort` is the proxy on `127.0.0.1` |
| `publishing`, `ready` | the onion is being published; other wallets reach this one at `onion` |
| `failed` | `failure` says why (`TorFailureKind`) |
| `sending` | a send or resend over Tor is reaching the other wallet |
| `received`, `refused` | a payment came in over Tor, as in the HTTP listener |
| `stopped` | tor and its listener ended; the last event |

With `publishOnion` false the stream stops at `bootstrapped`: tor carries the node, relay and
Tor-send connections only. With `HostPolicy.publishPreviousOnion` (the default) the wallet also
publishes `previousOnionAddress()` behind a second listener. `torStatus()` returns the current
`TorStatus` (`off`, `starting`, `bootstrapped`, `publishing`, `ready`).

App lifecycle calls:

| Call | When |
|---|---|
| `refreshTor(networkChanged:)` | the app returns to the foreground; `networkChanged` after the device changed network. Fails with `TorNotRunning` when no tor runs |
| `torNetworkLost()` | the device has no network; tor makes no attempt until the next `refreshTor` |
| `stopTor()` | stops tor, then its listener; sends over Tor in progress fail |

### What goes through Tor

| Setting | Default | Effect |
|---|---|---|
| `setEpicboxOverTor` | on | the relay connection goes through tor, to the relay's onion when one is known |
| `setHttpOverTor` | on | `sendHttp` and `resendHttp` go through tor; a host on this device stays direct |
| `setNodeOverTor` | on | every node request goes through tor |

Each setting applies only while tor runs or is expected (`WalletConfig.torWanted`, `expectTor()`).
While it applies, a connection never falls back to a direct one: it waits for tor, then fails.
`sendTor` always uses tor. `setOnionRoutes(routes:)` replaces the `OnionRoute` list (a host that is
also an onion service presenting the host's TLS certificate) that `WalletConfig.onionRoutes` set;
at most 256. `validateOnionAddress(address:)` checks an onion v3 address.
[LEPIC's Tor page](https://github.com/BTLabsUK/lepic/blob/main/docs/protocols/tor.md) describes the
routing.

`sendTor` reaches the other wallet at port 80, emits `sending` on the tor stream and takes up to
about 150 seconds to fail for an onion that is not online. It fails with `OnionAddressInvalid` and
`TorNotRunning` before it stores anything.

## Invoices

An invoice asks for a payment: the issuer makes it, the payer pays it, and the issuer finalizes the
payer's answer and posts the transaction. Slates have the stages I1 (the invoice), I2 (the
payer's answer) and I3 (the finalized transaction).

| Step | Issuer | Payer |
|---|---|---|
| By text | `issueInvoiceSlate(amount:, message:)` returns the I1 | `payInvoiceSlate(slateJson:, amount:, minimumConfirmations:, ...)` returns the I2 |
| By file | `issueInvoiceFile(amount:, path:)` | `payInvoiceFile(path:, amount:, ...)`, which also writes `<path>.response` |
| Finish | `finalizeAndPost(slateJson:)` with the I2 | |
| To a contact | `contactIssueInvoice` | `contactPayInvoice`, `contactDeclineInvoice` |

The payer calls `payInvoiceSlate` only after the user approved the amount, which must equal the
invoiced amount; the fee comes on top. The inputs stay locked until the issuer posts the
transaction or the payer cancels with `cancelTransaction`. The call fails with `InvalidSlate`,
`AmountMismatch`, `InvoiceAlreadyPaid`, `PaymentExpired`, `InvoiceNotForThisChain`,
`InvoiceLockedAboveTip`, `NotEnoughFunds` or `NodeUnreachable`, and stores nothing then.

An invoice has a time to live of 1,440 blocks from the node's tip. A LEPIC payer refuses it, and
the issuer refuses to finalize a payment of it, from 10 blocks before that. `cancelTransaction` on
an invoice the wallet issued withdraws it.

`sweepInvoices(expirySecs:)` expires what invoices left unpaid and returns an `InvoiceSweep`. Run
it from time to time, for example after collecting contact mail. Received invoices waiting longer
than `expirySecs` are deleted and issued ones are cancelled, each with an `invoiceExpired` event.
`expirySecs` defaults to a day and is at most two days. `InvoiceSweep.cancellable` lists payments
whose time to live passed with the transaction neither on chain nor in the pool; the app offers the
user `cancelTransaction` for them.
