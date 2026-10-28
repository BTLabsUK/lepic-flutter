// SPDX-License-Identifier: Apache-2.0
// Bundles the prebuilt lepic-ffi library for the Android, iOS, Linux or Windows target being
// built, so an app gets it by depending on this package. `tool/lepic.sh build` puts the libraries,
// built from the pinned LEPIC, in `native/<rust target>/` next to a `SHA256SUMS` manifest, which
// is checked before bundling; the `native_dir` user define points elsewhere. The `tor` user
// define, when set, also requires a library built with (true) or without (false) LEPIC's `tor`
// feature, as the `FEATURES` file next to it records (LEPIC ADR 0026). The `SOURCE` file next to
// the library must name the LEPIC commit in `lepic.rev`, built from an unmodified tree.
//
// `flutter test` on Linux runs this hook for the host too, so the package's own tests load the
// library it bundles. macOS builds get no asset.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

/// The library file stem flutter_rust_bridge opens (`stem` in `lib/src/rust/frb_generated.dart`).
const libraryStem = 'lepic_ffi';

/// Must match `ANDROID_API_LEVEL` in LEPIC's `xtask/src/mobile.rs`: the libraries link against
/// this API.
const androidApiLevel = 24;

/// Must match `MANIFEST_FILE` in LEPIC's `xtask/src/mobile.rs`: the `sha256sum` file written
/// next to each library.
const manifestFileName = 'SHA256SUMS';

/// Must match `FEATURES_FILE` in LEPIC's `xtask/src/mobile.rs`: the `lepic-ffi` features the
/// library next to it was built with, one per line.
const featuresFileName = 'FEATURES';

/// Must match `SOURCE_FILE` in LEPIC's `xtask/src/mobile.rs`: `lepic <commit>`, `tree clean` or
/// `tree modified`, and the rustc version, one per line.
const sourceFileName = 'SOURCE';

/// Throws unless [source] (the `SOURCE` file next to the library) says the library was built
/// from LEPIC at [rev], the commit in this package's `lepic.rev`, with no local changes. The
/// SHA-256 gate only proves the file is the one xtask packaged; this ties it to the pin.
void verifySource(File source, String rev, String target) {
  final repackage = 'Run `tool/lepic.sh build $target` in the lepic package.';
  if (!source.existsSync()) {
    throw StateError(
      'No $sourceFileName next to the $target library: it was packaged before LEPIC recorded '
      'its commit. $repackage',
    );
  }
  final lines = source.readAsLinesSync().map((line) => line.trim()).toList();
  if (!lines.contains('lepic $rev')) {
    final built = lines.firstWhere((line) => line.startsWith('lepic '), orElse: () => 'lepic ?');
    throw StateError(
      'The $target library was built from ${built.substring(6)}, not the pinned LEPIC $rev. '
      '$repackage',
    );
  }
  if (!lines.contains('tree clean')) {
    throw StateError(
      'The $target library was built from a LEPIC tree with local changes. $repackage',
    );
  }
}

/// Whether the library in [features] (the `FEATURES` file next to it) has LEPIC's `tor` feature.
/// A library packaged before LEPIC wrote the file has no file and always has Tor.
bool libraryHasTor(File features) =>
    !features.existsSync() ||
    features.readAsLinesSync().any((line) => line.trim() == 'tor');

/// Throws when the `tor` user define [wanted] is set and the library's [features] say otherwise,
/// so a build without Tor never bundles a library with it, nor the other way round.
void verifyTor(Object? wanted, File features, String target) {
  if (wanted == null) {
    return;
  }
  if (wanted is! bool) {
    throw StateError(
      'The lepic user define `tor` must be true or false, not $wanted.',
    );
  }
  final hasTor = libraryHasTor(features);
  if (hasTor != wanted) {
    final build = wanted
        ? '`tool/lepic.sh build $target`'
        : '`WFE_TOR=0 tool/lepic.sh build $target`';
    throw StateError(
      'The $target library was built ${hasTor ? 'with' : 'without'} Tor, but the lepic user '
      'define `tor` is $wanted. Run $build in the lepic package.',
    );
  }
}

/// Throws unless [manifest] exists and records the SHA-256 of [library], so a truncated,
/// mixed-up or replaced library is not bundled into the app.
void verifyLibrary(File library, File manifest, String target) {
  final repackage = 'Run `tool/lepic.sh build $target` in the lepic package.';
  if (!manifest.existsSync()) {
    throw StateError(
      'No $manifestFileName next to ${library.path}. $repackage',
    );
  }
  final name = library.uri.pathSegments.last;
  final entry = RegExp(r'^([0-9a-f]{64}) [ *](.+)$');
  final recorded = [
    for (final line in manifest.readAsLinesSync())
      if (entry.firstMatch(line) case final match? when match[2] == name)
        match[1],
  ];
  if (recorded.length != 1) {
    throw StateError(
      '${manifest.path} does not record one SHA-256 for $name. $repackage',
    );
  }
  final actual = sha256.convert(library.readAsBytesSync()).toString();
  if (actual != recorded.single) {
    throw StateError(
      '${library.path} does not match its SHA-256 in ${manifest.path}. $repackage',
    );
  }
}

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }
    final code = input.config.code;
    final target = rustTarget(code);
    if (target == null) {
      return;
    }
    if (code.linkModePreference == LinkModePreference.static) {
      throw UnsupportedError(
        'package:lepic ships $libraryStem as a dynamic library only.',
      );
    }

    final definedDir = input.userDefines.path('native_dir');
    // Directory.uri ends in a slash, so a user define written without one still resolves inside.
    final nativeDir = definedDir == null
        ? input.packageRoot.resolve('native/')
        : Directory.fromUri(definedDir).uri;
    final library = File.fromUri(
      nativeDir.resolve('$target/${code.targetOS.dylibFileName(libraryStem)}'),
    );
    if (!library.existsSync()) {
      throw StateError(
        'No $target library at ${library.path}. Run '
        '`tool/lepic.sh build $target` in the lepic package.',
      );
    }
    final manifest = File.fromUri(library.uri.resolve(manifestFileName));
    verifyLibrary(library, manifest, target);
    final features = File.fromUri(library.uri.resolve(featuresFileName));
    verifyTor(input.userDefines['tor'], features, target);
    final source = File.fromUri(library.uri.resolve(sourceFileName));
    final rev = File.fromUri(input.packageRoot.resolve('lepic.rev'));
    verifySource(source, rev.readAsStringSync().trim(), target);

    output.dependencies
      ..add(library.uri)
      ..add(manifest.uri)
      ..add(source.uri)
      ..add(rev.uri);
    if (features.existsSync()) {
      output.dependencies.add(features.uri);
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/rust/frb_generated.io.dart',
        linkMode: DynamicLoadingBundled(),
        file: library.uri,
      ),
    );
  });
}

/// The Rust target triple for a build, or null when this package bundles nothing for the target.
/// Throws for an Android, iOS, Linux or Windows target LEPIC does not build.
String? rustTarget(CodeConfig code) {
  final arch = code.targetArchitecture;
  switch (code.targetOS) {
    case OS.android:
      final api = code.android.targetNdkApi;
      if (api < androidApiLevel) {
        throw UnsupportedError(
          'package:lepic needs Android API $androidApiLevel or later; '
          'the app builds for API $api (raise minSdk).',
        );
      }
      return switch (arch) {
        Architecture.arm64 => 'aarch64-linux-android',
        Architecture.arm => 'armv7-linux-androideabi',
        Architecture.x64 => 'x86_64-linux-android',
        _ => throw UnsupportedError(
          'package:lepic has no Android $arch build.',
        ),
      };
    case OS.iOS:
      final simulator = code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
      return switch ((arch, simulator)) {
        (Architecture.arm64, false) => 'aarch64-apple-ios',
        (Architecture.arm64, true) => 'aarch64-apple-ios-sim',
        _ => throw UnsupportedError(
          'package:lepic has no iOS ${simulator ? 'simulator ' : ''}$arch build.',
        ),
      };
    case OS.linux:
      return switch (arch) {
        Architecture.x64 => 'x86_64-unknown-linux-gnu',
        _ => throw UnsupportedError('package:lepic has no Linux $arch build.'),
      };
    case OS.windows:
      return switch (arch) {
        Architecture.x64 => 'x86_64-pc-windows-msvc',
        _ => throw UnsupportedError(
          'package:lepic has no Windows $arch build.',
        ),
      };
    default:
      return null;
  }
}
