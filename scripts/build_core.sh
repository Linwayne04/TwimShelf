#!/bin/zsh
# Builds tl-core for the current Xcode platform into $BUILT_PRODUCTS_DIR.
set -e
source ~/.cargo/env
cd "$SRCROOT/core"
case "$PLATFORM_NAME" in
  iphoneos) T=aarch64-apple-ios; S=iphoneos ;;
  iphonesimulator) T=aarch64-apple-ios-sim; S=iphonesimulator ;;
  *) T=aarch64-apple-darwin; S=macosx ;;
esac
# Always optimize the core: crypto/hashing generics are instantiated in our crate, and an
# unoptimized core syncs ~14x slower (8 vs 110 MB/s measured). Debug info stays in release builds.
P=release
FLAG=--release
env -i HOME="$HOME" PATH="$HOME/.cargo/bin:/usr/bin:/bin" SDKROOT="$(xcrun --sdk $S --show-sdk-path)" DEVELOPER_DIR="$DEVELOPER_DIR" cargo build $FLAG --target $T
cp "target/$T/$P/libtl_core.a" "$BUILT_PRODUCTS_DIR/libtl_core.a"
