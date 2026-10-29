#!/usr/bin/env bash
set -euo pipefail
platform="${1:?windows or macos}"; destination="${2:?absolute output directory}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/droidframe-ffmpeg-$platform"
if [ "$platform" = windows ]; then
  build="$(cygpath -u "$build")"
  destination="$(cygpath -u "$destination")"
fi
mkdir -p "$build/source" "$destination/Sources" "$destination/Licenses"
fetch() { if [ ! -f "$2" ]; then curl --retry 3 -fsSL "$1" -o "$2"; fi; }
check() { actual=$(openssl dgst -sha256 "$1" | awk '{print $NF}'); [ "$actual" = "$2" ] || { echo "Checksum mismatch: $1"; exit 1; }; }
fetch https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n8.0.tar.gz "$build/ffmpeg-n8.0.tar.gz"
fetch https://github.com/mirror/x264/archive/31e19f92f00c7003fa115047ce50978bc98c3a0d.tar.gz "$build/x264.tar.gz"
check "$build/ffmpeg-n8.0.tar.gz" dd4030dbfdc34d9ff255a116bdd1caade42500ac2981efa27f8b151cc54c7b9e
check "$build/x264.tar.gz" d053c9d86988d6bc78237ca5205865c5ddf99c98ef4cd9927eec8f6d388f6dd9
cp "$build/ffmpeg-n8.0.tar.gz" "$build/x264.tar.gz" "$destination/Sources/"
cp "$repo/scripts/build-ffmpeg.sh" "$destination/Sources/"
mkdir -p "$build/source/x264" "$build/source/ffmpeg"
tar -xzf "$build/x264.tar.gz" --strip-components=1 -C "$build/source/x264"
tar -xzf "$build/ffmpeg-n8.0.tar.gz" --strip-components=1 -C "$build/source/ffmpeg"
prefix="$build/prefix"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
xargs=(); fargs=()
if [ "$platform" = windows ]; then
  xargs+=(--host=x86_64-w64-mingw32)
  fargs+=(--target-os=mingw32 --arch=x86_64 --extra-ldflags=-static)
else
  export MACOSX_DEPLOYMENT_TARGET=13.0
  xargs+=(--host=aarch64-apple-darwin --extra-cflags=-mmacosx-version-min=13.0 --extra-asflags=-mmacosx-version-min=13.0 --extra-ldflags=-mmacosx-version-min=13.0)
  fargs+=(--cc=clang --target-os=darwin --arch=aarch64 --extra-cflags=-mmacosx-version-min=13.0 --extra-ldflags=-mmacosx-version-min=13.0)
fi
cd "$build/source/x264"
./configure --prefix="$prefix" --enable-static --disable-shared --disable-cli --disable-opencl --bit-depth=8 --chroma-format=420 "${xargs[@]}"
make -j2; make install
if ! command -v pkg-config >/dev/null; then
  export DROIDFRAME_X264_PREFIX="$prefix"
  cat > "$build/pkg-config-x264" <<'PKG'
#!/bin/sh
case "$*" in --version) echo 1.0; exit 0;; *x264*) ;; *) exit 1;; esac
case "$*" in
  *--exists*) exit 0;;
  *--cflags*) echo "-I$DROIDFRAME_X264_PREFIX/include";;
  *--libs*) echo "-L$DROIDFRAME_X264_PREFIX/lib -lx264 -lpthread -lm";;
  *--variable=includedir*) echo "$DROIDFRAME_X264_PREFIX/include";;
  *--modversion*) echo 0.164;;
esac
PKG
  chmod +x "$build/pkg-config-x264"
  cp "$build/pkg-config-x264" "$destination/Sources/"
  fargs+=(--pkg-config="$build/pkg-config-x264")
fi
cd "$build/source/ffmpeg"
./configure --prefix="$prefix" --disable-shared --enable-static --disable-autodetect --disable-everything --enable-ffmpeg --enable-ffprobe --disable-ffplay --disable-doc --disable-network --enable-gpl --enable-libx264 --pkg-config-flags=--static --enable-encoder=libx264,aac,wrapped_avframe,pcm_s16le --enable-decoder=h264,hevc,aac,rawvideo,wrapped_avframe,pcm_s16le,pcm_s24le,pcm_f32le --enable-demuxer=mov --enable-indev=lavfi --enable-muxer=mp4,null --enable-protocol=file,pipe --enable-filter=scale,format,aresample,anull,null,tpad,fps,testsrc2,sine --enable-parser=h264,hevc,aac --enable-bsf=aac_adtstoasc,h264_mp4toannexb,hevc_mp4toannexb "${fargs[@]}"
make -j2
if [ "$platform" = windows ]; then cp ffmpeg.exe ffprobe.exe "$destination/"; else cp ffmpeg ffprobe "$destination/"; fi
cp COPYING.GPLv2 COPYING.GPLv3 "$destination/Licenses/"
cp "$build/source/x264/COPYING" "$destination/Licenses/x264-COPYING"
cp ffbuild/config.log config.h ffbuild/config.mak "$destination/Sources/"
printf '%s\n' 'FFmpeg 8.0 + x264 31e19f92. GPL v2 or later. Full corresponding sources and build script are in Sources/. Build requires compiler tools; normal use requires no installation.' > "$destination/README.txt"
