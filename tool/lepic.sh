#!/usr/bin/env bash
# Builds, tests and generates package:lepic against the LEPIC commit in lepic.rev.
#
# Usage:
#   tool/lepic.sh sync                  clone LEPIC into third_party/lepic at the pin
#   tool/lepic.sh build <what>...       release libraries into native/<triple>/: linux, android,
#                                       windows, all (every target this host builds) or triples
#   tool/lepic.sh test [<args>]         flutter test against the scripted-node library
#   tool/lepic.sh emulator-test [<serial>]
#                                       the device test app on an attached Android device
#   tool/lepic.sh generate              both bridge halves from LEPIC's crates/lepic-ffi/src/api
#   tool/lepic.sh check                 fail unless both halves match the pinned LEPIC
#   tool/lepic.sh lib                   print the path of the Linux library
#
# WFE_TOR=0 (also false or off), the app's switch for its build without Tor, makes `build` leave
# LEPIC's tor out (`cargo xtask mobile --package --no-tor`, LEPIC ADR 0026); unset or anything
# else builds with Tor, as before.
#
# LEPIC_DIR names a LEPIC checkout to use instead of third_party/lepic. It must be clean and at
# the pin, except for `generate`, which may run on any commit and writes into it. LEPIC_REPO is
# where `sync` clones from, by default the GitHub repository.
set -euo pipefail

package="$(cd "$(dirname "$0")/.." && pwd)"
rev="$(tr -d '[:space:]' < "$package/lepic.rev")"
lepic="${LEPIC_DIR:-$package/third_party/lepic}"
lepic_repo="${LEPIC_REPO:-https://github.com/BTLabs-EPIC/lepic.git}"
# One target directory per checkout: xtask finds the libraries it builds under it.
unset CARGO_TARGET_DIR

# Must match ANDROID_TARGETS and LINUX_TARGETS in LEPIC's xtask/src/mobile.rs.
android_targets=(aarch64-linux-android armv7-linux-androideabi x86_64-linux-android)
linux_target=x86_64-unknown-linux-gnu
windows_target=x86_64-pc-windows-msvc
# The generated files, relative to the package and to LEPIC's lepic-ffi crate.
dart_output=lib/src/rust
rust_generated=src/frb_generated.rs
bridge_manifest=bridge.sha256

die() { echo "lepic.sh: $*" >&2; exit 1; }

require_checkout() {
  [ -e "$lepic/.git" ] || die "no LEPIC checkout at $lepic: run tool/lepic.sh sync, or set LEPIC_DIR"
  [ -f "$lepic/crates/lepic-ffi/Cargo.toml" ] || die "$lepic is not a LEPIC checkout"
}

require_pin() {
  require_checkout
  [ "$(git -C "$lepic" rev-parse HEAD)" = "$rev" ] \
    || die "LEPIC at $lepic is not at the pin $rev: run tool/lepic.sh sync"
  [ -z "$(git -C "$lepic" status --porcelain --untracked-files=no)" ] \
    || die "LEPIC at $lepic has local changes; it must match the pin exactly"
}

# Whether WFE_TOR asks for the build without Tor.
without_tor() {
  case "${WFE_TOR:-1}" in
    0|false|off) return 0 ;;
    *) return 1 ;;
  esac
}

# Builds the release lepic-ffi library for each target into a directory, through LEPIC's xtask,
# without Tor when WFE_TOR says so.
package_libraries() {
  local out="$1"; shift
  local args=()
  without_tor && args+=(--no-tor)
  for target in "$@"; do args+=(--target "$target"); done
  (cd "$lepic" && cargo xtask mobile --package --out "$out" "${args[@]}")
}

# The scripted-node library, in a target directory of its own so it never replaces the
# shipped build's artifacts.
package_mock() {
  local out="$1" target="$2"
  (cd "$lepic" && CARGO_TARGET_DIR="$lepic/target/mock" \
    cargo xtask mobile --package --mock --out "$out" --target "$target")
}

host_targets() {
  case "$(uname -s)" in
    Linux) echo "$linux_target ${android_targets[*]}" ;;
    MINGW*|MSYS*|CYGWIN*) echo "$windows_target ${android_targets[*]}" ;;
    *) echo "${android_targets[*]}" ;;
  esac
}

frb_version() {
  sed -n 's/^  flutter_rust_bridge: \([0-9.]*\)$/\1/p' "$package/pubspec.yaml"
}

locked_frb_version() {
  awk '/^name = "flutter_rust_bridge"$/ { found = 1; next }
       found && /^version = / { gsub(/"/, "", $3); print $3; exit }' "$lepic/Cargo.lock"
}

# Same versions everywhere: the Dart runtime, LEPIC's Rust crate and the code generator.
check_versions() {
  local dart rust codegen
  dart="$(frb_version)"
  rust="$(locked_frb_version)"
  codegen="$(flutter_rust_bridge_codegen --version 2>/dev/null | awk '{ print $2 }')" \
    || die "flutter_rust_bridge_codegen is not installed"
  [ -n "$dart" ] && [ "$dart" = "$rust" ] && [ "$dart" = "$codegen" ] \
    || die "flutter_rust_bridge versions differ: pubspec.yaml '$dart', LEPIC Cargo.lock '$rust', codegen '$codegen'"
}

generate() {
  check_versions
  # From LEPIC's crate, outside the package: there cargo uses LEPIC's toolchain, and `dart run`
  # inside the package would first run its build hook, which needs a library not built yet.
  (cd "$lepic/crates/lepic-ffi" && dart "$package/tool/generate.dart" "$lepic/crates/lepic-ffi" \
    "$package/$dart_output")
  # What the halves were generated from, for LEPIC's `cargo xtask repo-lint`.
  (cd "$lepic/crates/lepic-ffi" \
    && { find src/api -type f | LC_ALL=C sort | xargs sha256sum; sha256sum "$rust_generated"; } \
       > "$bridge_manifest")
}

case "${1:-}" in
  sync)
    [ -z "${LEPIC_DIR:-}" ] || die "LEPIC_DIR is set: sync only manages third_party/lepic"
    if [ ! -d "$lepic/.git" ]; then
      mkdir -p "$(dirname "$lepic")"
      git clone --quiet --no-checkout "$lepic_repo" "$lepic"
    fi
    git -C "$lepic" fetch --quiet "$lepic_repo" '+refs/heads/*:refs/remotes/origin/*'
    git -C "$lepic" checkout --quiet --detach "$rev"
    echo "LEPIC at $(git -C "$lepic" log --oneline -1)"
    ;;
  build)
    require_pin
    shift
    [ $# -gt 0 ] || set -- all
    targets=()
    for what in "$@"; do
      case "$what" in
        linux) targets+=("$linux_target") ;;
        android) targets+=("${android_targets[@]}") ;;
        windows) targets+=("$windows_target") ;;
        all) read -r -a host <<< "$(host_targets)"; targets+=("${host[@]}") ;;
        *-*) targets+=("$what") ;;
        *) die "unknown build '$what': linux, android, windows, all or a Rust target triple" ;;
      esac
    done
    package_libraries "$package/native" "${targets[@]}"
    if without_tor; then
      echo "libraries without Tor: $package/native/"
    else
      echo "libraries: $package/native/"
    fi
    ;;
  test)
    require_pin
    shift
    package_mock "$package/test_native" "$linux_target"
    (cd "$package" && LEPIC_DIR="$lepic" flutter test "$@")
    ;;
  emulator-test)
    require_pin
    adb="${ANDROID_HOME:+$ANDROID_HOME/platform-tools/}adb"
    [ -x "$adb" ] || adb=adb
    mapfile -t ready < <("$adb" devices | awk 'NR > 1 && $2 == "device" { print $1 }')
    if [ -n "${2:-}" ]; then
      printf '%s\n' "${ready[@]}" | grep -qx -- "$2" \
        || die "device '$2' is not attached and ready (adb devices)"
      device="$2"
    else
      case "${#ready[@]}" in
        0) die "no Android device is attached; start an emulator first" ;;
        1) device="${ready[0]}" ;;
        *) die "several devices are attached (${ready[*]}); name one" ;;
      esac
    fi
    abi="$("$adb" -s "$device" shell getprop ro.product.cpu.abi | tr -d '[:space:]')"
    case "$abi" in
      arm64-v8a) target=aarch64-linux-android ;;
      armeabi-v7a) target=armv7-linux-androideabi ;;
      x86_64) target=x86_64-linux-android ;;
      *) die "LEPIC has no Android build for the device ABI '$abi'" ;;
    esac
    package_mock "$package/emulator_test/native" "$target"
    (cd "$package/emulator_test" && flutter test integration_test -d "$device")
    ;;
  generate)
    require_checkout
    [ "$(git -C "$lepic" rev-parse HEAD)" = "$rev" ] \
      || echo "lepic.sh: LEPIC at $lepic is not at the pin $rev; generating from it anyway" >&2
    generate
    echo "generated $dart_output/ here and crates/lepic-ffi/{$rust_generated,$bridge_manifest} in $lepic"
    echo "commit the LEPIC files there, then move lepic.rev to that commit and commit $dart_output/ here"
    ;;
  check)
    require_pin
    [ -z "$(git -C "$package" status --porcelain -- "$dart_output")" ] \
      || die "$dart_output has uncommitted changes; check compares against the committed files"
    generate
    drift=0
    if [ -n "$(git -C "$package" status --porcelain -- "$dart_output")" ]; then
      git -C "$package" status --short -- "$dart_output" >&2
      echo "lepic.sh: the Dart half differs from what LEPIC $rev generates" >&2
      drift=1
    fi
    if [ -n "$(git -C "$lepic" status --porcelain -- crates/lepic-ffi)" ]; then
      git -C "$lepic" status --short -- crates/lepic-ffi >&2
      echo "lepic.sh: LEPIC $rev holds a Rust half that does not match its API" >&2
      drift=1
    fi
    [ "$drift" = 0 ] || die "the bridge halves drifted: run tool/lepic.sh generate and commit both"
    echo "bridge halves match LEPIC $rev"
    ;;
  lib)
    echo "$package/native/$linux_target/liblepic_ffi.so"
    ;;
  *)
    sed -n '4,21p' "$0" >&2
    exit 2
    ;;
esac
