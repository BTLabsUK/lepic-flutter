// SPDX-License-Identifier: Apache-2.0
// Regenerates the bindings: runs `flutter_rust_bridge_codegen generate`, then makes every stream
// decode its errors as `WalletError`.
//
// flutter_rust_bridge 2.13.0 always decodes a `StreamSink` error as `AnyhowException`. Every
// stream call of LEPIC's `lepic-ffi` ends its stream with a `WalletError` instead, the type every
// other call throws, so the decoder of each stream sink is replaced here.
//
// This file is the codegen configuration: the API is `crate::api` of LEPIC's `lepic-ffi`, and the
// Dart half goes to `lib/src/rust`. Run it through `tool/lepic.sh generate`, which passes the
// `lepic-ffi` directory of a LEPIC checkout and the Dart output directory:
//
//   dart <package>/tool/generate.dart <lepic>/crates/lepic-ffi <package>/lib/src/rust

import 'dart:io';

const rustInput = 'crate::api';

/// The library file stem, `lepic-ffi`'s lib target, which the build hook bundles under that name.
const libraryStem = 'lepic_ffi';

/// The codegen derives `ioDirectory`, a directory under the working directory searched first for
/// the library, from where the LEPIC checkout sits. It is set to null: a shipped app must not
/// look for its library under whatever directory it was started from. Tests and `dart run` pass
/// the library file to `RustLib.init`.
final ioDirectoryItem = RegExp(r"ioDirectory:\s*(?:'[^']*'|null),");
const anyhowDecoder = 'decodeErrorData: sse_decode_AnyhowException,';
const walletErrorDecoder = 'decodeErrorData: sse_decode_wallet_error,';

/// The body of every generated `sse_encode_StreamSink_*` function, which builds the codec of
/// one stream.
final streamSinkEncoder = RegExp(
  r'void sse_encode_StreamSink_\w+\([^)]*\)\s*\{.*?\n  \}',
  dotAll: true,
);

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart tool/generate.dart <lepic-ffi directory> <dart output>');
    exit(2);
  }
  final [rustRoot, dartOutput] = args;
  final generated = '$dartOutput/frb_generated.dart';
  final codegen = await Process.start('flutter_rust_bridge_codegen', [
    'generate',
    '--rust-root',
    rustRoot,
    '--rust-input',
    rustInput,
    '--dart-output',
    dartOutput,
  ], mode: ProcessStartMode.inheritStdio, workingDirectory: rustRoot);
  final exitCode = await codegen.exitCode;
  if (exitCode != 0) {
    stderr.writeln(
      'flutter_rust_bridge_codegen failed with exit code $exitCode',
    );
    exit(exitCode);
  }

  final file = File(generated);
  var source = await file.readAsString();
  if (!source.contains("stem: '$libraryStem',")) {
    stderr.writeln(
      '$generated does not load the library as $libraryStem: the codegen could not read '
      '$rustRoot/Cargo.toml with LEPIC\'s toolchain.',
    );
    exit(1);
  }
  if (ioDirectoryItem.allMatches(source).length != 1) {
    stderr.writeln('expected one ioDirectory in $generated: check tool/generate.dart');
    exit(1);
  }
  source = source.replaceFirst(ioDirectoryItem, 'ioDirectory: null,');
  var sinks = 0;
  var replaced = 0;
  final patched = source.replaceAllMapped(streamSinkEncoder, (match) {
    sinks++;
    final encoder = match[0]!;
    if (encoder.contains(anyhowDecoder)) replaced++;
    return encoder.replaceAll(anyhowDecoder, walletErrorDecoder);
  });
  if (sinks == 0 || replaced != sinks) {
    stderr.writeln(
      'expected every stream sink in $generated to decode AnyhowException errors; '
      'found $sinks sinks, $replaced of them with that decoder. '
      'The codegen output changed: check tool/generate.dart against it.',
    );
    exit(1);
  }
  await file.writeAsString(patched);
  stdout.writeln('$replaced stream sinks decode WalletError');
}
