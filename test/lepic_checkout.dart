// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

/// [relative] inside the LEPIC checkout the package is tested against: `LEPIC_DIR`, which
/// `tool/lepic.sh test` sets, or else `third_party/lepic`, where `tool/lepic.sh sync` puts it.
String lepicPath(String relative) {
  final dir = Platform.environment['LEPIC_DIR'] ?? 'third_party/lepic';
  return File('$dir/$relative').absolute.path;
}
