// SPDX-License-Identifier: Apache-2.0
// Runs hook/build.dart in isolation for each target it handles. Needs no native library: the
// bundling cases point the `native_dir` user define at stand-in files.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks/hooks.dart';

import '../hook/build.dart' as hook;

late Directory nativeDir;

PackageUserDefines nativeDirDefine({Object? tor}) => PackageUserDefines(
  workspacePubspec: PackageUserDefinesSource(
    defines: {'native_dir': nativeDir.path, 'tor': ?tor},
    basePath: nativeDir.uri,
  ),
);

/// SHA-256 of the single zero byte every stand-in library holds.
const standInSha256 =
    '6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d';

/// The LEPIC commit this package pins.
final pinnedRev = File('lepic.rev').readAsStringSync().trim();

/// A stand-in library and, unless [manifest] is false, its `SHA256SUMS` as LEPIC's xtask writes
/// it, with a `SOURCE` that names [rev] (the pin by default) and [tree].
File standIn(
  String target,
  String fileName, {
  bool manifest = true,
  String? rev,
  String tree = 'clean',
  bool source = true,
}) {
  final library = File('${nativeDir.path}/$target/$fileName')
    ..createSync(recursive: true)
    ..writeAsBytesSync([0]);
  if (manifest) {
    File('${nativeDir.path}/$target/SHA256SUMS')
        .writeAsStringSync('$standInSha256  $fileName\n');
  }
  if (source) {
    File('${nativeDir.path}/$target/SOURCE')
        .writeAsStringSync('lepic ${rev ?? pinnedRev}\ntree $tree\nrustc 1.99.0\n');
  }
  return library;
}

Future<List<CodeAsset>> bundled({
  required OS os,
  required Architecture arch,
  IOSSdk iosSdk = IOSSdk.iPhoneOS,
  int androidApi = 30,
  LinkModePreference linkMode = LinkModePreference.dynamic,
  Object? tor,
}) async {
  late List<CodeAsset> assets;
  await testCodeBuildHook(
    mainMethod: hook.main,
    targetOS: os,
    targetArchitecture: arch,
    targetIOSSdk: iosSdk,
    targetAndroidNdkApi: androidApi,
    linkModePreference: linkMode,
    userDefines: nativeDirDefine(tor: tor),
    check: (input, output) => assets = output.assets.code,
  );
  return assets;
}

void main() {
  setUp(() => nativeDir = Directory.systemTemp.createTempSync('lepic_native_'));
  tearDown(() => nativeDir.deleteSync(recursive: true));

  test('bundles the android library for each abi as the frb asset', () async {
    for (final (arch, target) in [
      (Architecture.arm64, 'aarch64-linux-android'),
      (Architecture.arm, 'armv7-linux-androideabi'),
      (Architecture.x64, 'x86_64-linux-android'),
    ]) {
      final library = standIn(target, 'liblepic_ffi.so');
      final assets = await bundled(os: OS.android, arch: arch);
      expect(assets, hasLength(1));
      expect(assets.single.id, 'package:lepic/src/rust/frb_generated.io.dart');
      expect(assets.single.linkMode, isA<DynamicLoadingBundled>());
      expect(assets.single.file, library.uri);
    }
  });

  test('bundles the ios device and simulator libraries', () async {
    final device = standIn('aarch64-apple-ios', 'liblepic_ffi.dylib');
    final simulator = standIn('aarch64-apple-ios-sim', 'liblepic_ffi.dylib');
    expect(
      (await bundled(os: OS.iOS, arch: Architecture.arm64)).single.file,
      device.uri,
    );
    expect(
      (await bundled(
        os: OS.iOS,
        arch: Architecture.arm64,
        iosSdk: IOSSdk.iPhoneSimulator,
      )).single.file,
      simulator.uri,
    );
  });

  test('bundles the linux x64 library', () async {
    final library = standIn('x86_64-unknown-linux-gnu', 'liblepic_ffi.so');
    final assets = await bundled(os: OS.linux, arch: Architecture.x64);
    expect(assets, hasLength(1));
    expect(assets.single.id, 'package:lepic/src/rust/frb_generated.io.dart');
    expect(assets.single.linkMode, isA<DynamicLoadingBundled>());
    expect(assets.single.file, library.uri);
  });

  test('bundles the windows x64 library', () async {
    final library = standIn('x86_64-pc-windows-msvc', 'lepic_ffi.dll');
    final assets = await bundled(os: OS.windows, arch: Architecture.x64);
    expect(assets, hasLength(1));
    expect(assets.single.id, 'package:lepic/src/rust/frb_generated.io.dart');
    expect(assets.single.linkMode, isA<DynamicLoadingBundled>());
    expect(assets.single.file, library.uri);
  });

  test('bundles nothing for macos builds', () async {
    expect(await bundled(os: OS.macOS, arch: Architecture.arm64), isEmpty);
  });

  test('fails with the packaging command when the library is missing', () {
    expect(
      bundled(os: OS.android, arch: Architecture.arm64),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('tool/lepic.sh build'),
        ),
      ),
    );
  });

  Matcher failsWith(String text) => throwsA(
    isA<StateError>().having((e) => e.message, 'message', contains(text)),
  );

  test('fails without the sha256 manifest next to the library', () async {
    standIn('aarch64-linux-android', 'liblepic_ffi.so', manifest: false);
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64),
      failsWith('No SHA256SUMS'),
    );
  });

  test('fails when the library does not match its manifest', () async {
    final library = standIn('aarch64-linux-android', 'liblepic_ffi.so');
    library.writeAsBytesSync([1]);
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64),
      failsWith('does not match its SHA-256'),
    );
  });

  test('fails when the manifest names another file', () async {
    standIn('aarch64-linux-android', 'liblepic_ffi.so');
    File('${nativeDir.path}/aarch64-linux-android/SHA256SUMS')
        .writeAsStringSync('$standInSha256  liblepic_ffi.dylib\n');
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64),
      failsWith('does not record one SHA-256'),
    );
  });

  /// Writes the `FEATURES` file LEPIC's xtask puts next to a library built with [features].
  void featuresFile(String target, List<String> features) =>
      File('${nativeDir.path}/$target/FEATURES')
          .writeAsStringSync(features.map((f) => '$f\n').join());

  test('fails without a SOURCE naming the pinned LEPIC commit', () async {
    standIn('aarch64-linux-android', 'liblepic_ffi.so', source: false);
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64),
      failsWith('No SOURCE'),
    );
  });

  test('fails when the library was built from another LEPIC commit', () async {
    standIn('aarch64-linux-android', 'liblepic_ffi.so', rev: '0' * 40);
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64),
      failsWith('not the pinned LEPIC'),
    );
  });

  test('fails when the library was built from a modified LEPIC tree', () async {
    standIn('aarch64-linux-android', 'liblepic_ffi.so', tree: 'modified');
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64),
      failsWith('local changes'),
    );
  });

  test('takes any library when the tor user define is not set', () async {
    final library = standIn('x86_64-unknown-linux-gnu', 'liblepic_ffi.so');
    featuresFile('x86_64-unknown-linux-gnu', []);
    expect(
      (await bundled(os: OS.linux, arch: Architecture.x64)).single.file,
      library.uri,
    );
  });

  test(
    'bundles a library without tor when the tor user define is false',
    () async {
      final library = standIn('aarch64-linux-android', 'liblepic_ffi.so');
      featuresFile('aarch64-linux-android', []);
      expect(
        (await bundled(
          os: OS.android,
          arch: Architecture.arm64,
          tor: false,
        )).single.file,
        library.uri,
      );
      featuresFile('aarch64-linux-android', ['tor']);
      await expectLater(
        bundled(os: OS.android, arch: Architecture.arm64, tor: false),
        failsWith('built with Tor'),
      );
    },
  );

  test('wants tor in the library when the tor user define is true', () async {
    final library = standIn('aarch64-linux-android', 'liblepic_ffi.so');
    // A library packaged before the FEATURES file existed has Tor.
    expect(
      (await bundled(
        os: OS.android,
        arch: Architecture.arm64,
        tor: true,
      )).single.file,
      library.uri,
    );
    featuresFile('aarch64-linux-android', ['mock']);
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64, tor: true),
      failsWith('built without Tor'),
    );
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64, tor: 'no'),
      failsWith('must be true or false'),
    );
  });

  test('rejects targets lepic does not build', () async {
    standIn('aarch64-linux-android', 'liblepic_ffi.so');
    await expectLater(
      bundled(os: OS.android, arch: Architecture.arm64, androidApi: 23),
      throwsUnsupportedError,
    );
    await expectLater(
      bundled(
        os: OS.android,
        arch: Architecture.arm64,
        linkMode: LinkModePreference.static,
      ),
      throwsUnsupportedError,
    );
    await expectLater(
      bundled(
        os: OS.iOS,
        arch: Architecture.x64,
        iosSdk: IOSSdk.iPhoneSimulator,
      ),
      throwsUnsupportedError,
    );
    await expectLater(
      bundled(os: OS.linux, arch: Architecture.arm64),
      throwsUnsupportedError,
    );
  });
}
