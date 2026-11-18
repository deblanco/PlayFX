#!/usr/bin/env bash
# Builds libchiaki (PS4/PS5 Remote Play protocol, from third_party/chiaki-ng) as static
# libraries for macOS and stages them for StreamCore:
#   vendor/macos/lib/*.a                 libchiaki + its dependencies
#   Sources/CChiaki/include/chiaki/*.h   public headers (incl. generated config.h)
# Requires: brew install cmake ninja openssl@3 opus json-c miniupnpc libevent
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
CHIAKI="$PKG/../../third_party/chiaki-ng"
BUILD="$PKG/.build-chiaki/macos"
OUT_LIB="$PKG/vendor/macos/lib"
OUT_INC="$PKG/Sources/CChiaki/include/chiaki"

git -C "$CHIAKI" submodule update --init --depth 1 \
  third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl

# nanopb's generator needs a protoc matching its python-protobuf; grpcio-tools bundles both.
VENV="$PKG/.build-chiaki/venv"
[ -x "$VENV/bin/python" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q grpcio-tools; }

# Pin OpenSSL 3 explicitly: Homebrew may also have OpenSSL 4 linked into /opt/homebrew/include,
# which bundled curl does not compile against. Opus is pointed at its keg for the same reason.
OPENSSL="$(brew --prefix openssl@3)"
cmake -S "$CHIAKI" -B "$BUILD" -G Ninja \
  -DPYTHON_EXECUTABLE="$VENV/bin/python" -DPython3_EXECUTABLE="$VENV/bin/python" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DBUILD_SHARED_LIBS=OFF \
  -DOPENSSL_ROOT_DIR="$OPENSSL" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOpus_INCLUDE_DIRS="$(brew --prefix opus)/include" \
  -DCHIAKI_ENABLE_TESTS=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_GUI=OFF \
  -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
  -DCHIAKI_ENABLE_SPEEX=OFF -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF \
  -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DCHIAKI_LIB_ENABLE_OPUS=ON \
  -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
  -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_APPLE_IDN=OFF -DCURL_DISABLE_LDAP=ON
cmake --build "$BUILD" --target chiaki-lib

rm -rf "$OUT_LIB" "$OUT_INC"
mkdir -p "$OUT_LIB" "$OUT_INC"
# Libraries built from the chiaki tree (chiaki, nanopb, jerasure, gf-complete, curl)
find "$BUILD" -name '*.a' -exec cp {} "$OUT_LIB/" \;
# Homebrew-provided static dependencies
for f in "$OPENSSL/lib/libssl.a" "$OPENSSL/lib/libcrypto.a" \
         "$(brew --prefix opus)/lib/libopus.a" "$(brew --prefix json-c)/lib/libjson-c.a" \
         "$(brew --prefix miniupnpc)/lib/libminiupnpc.a" "$(brew --prefix libevent)/lib/libevent.a"; do
  cp "$f" "$OUT_LIB/"
done

cp -R "$CHIAKI/lib/include/chiaki/." "$OUT_INC/"
cp "$BUILD/lib/include/chiaki/config.h" "$OUT_INC/"
echo "libchiaki staged:"; ls "$OUT_LIB"
