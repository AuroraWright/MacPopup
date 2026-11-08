#!/bin/zsh
# Builds a small LGPL ffmpeg for the cards made from video players' lines (see iina-plugin/): the sentence audio cut
# out of the video file (AAC in .m4a) and a frame of the line (JPEG or PNG). Local files only, the usual containers
# and codecs; AV1 video through dav1d, which needs meson and ninja (without them, no AV1).
# Usage: scripts/build-ffmpeg.sh <ffmpeg version> <sha256> <dav1d version> <sha256> <out dir>; leaves
# <out dir>/ffmpeg and the licenses.
set -euo pipefail

FFMPEG_VERSION="$1"
FFMPEG_SHA256="$2"
DAV1D_VERSION="$3"
DAV1D_SHA256="$4"
OUT="${5:A}"
WORK="$OUT.work"
JOBS="$(sysctl -n hw.ncpu)"

# download <url> <sha256> <file>
download() {
    curl -fsSL -o "$3" "$1"
    if [[ "$(shasum -a 256 "$3" | cut -d' ' -f1)" != "$2" ]]; then
        echo "$1 doesn't have the expected SHA-256" >&2
        exit 1
    fi
}

rm -rf "$WORK"
mkdir -p "$WORK"
download "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "$FFMPEG_SHA256" "$WORK/ffmpeg.tar.xz"
tar -xJf "$WORK/ffmpeg.tar.xz" -C "$WORK"
SRC="$WORK/ffmpeg-$FFMPEG_VERSION"

DEMUXERS=matroska,mov,mpegts,mpegps,avi,flv,ogg,asf,mp3,aac,flac,wav,ac3,eac3,dts,truehd
DECODERS=aac,aac_latm,ac3,eac3,dca,truehd,mlp,flac,alac,opus,vorbis,mp1,mp2,mp3,wmav1,wmav2
DECODERS=$DECODERS,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_u8,pcm_bluray,pcm_dvd
DECODERS=$DECODERS,h264,hevc,vp8,vp9,mpeg1video,mpeg2video,mpeg4
PARSERS=aac,aac_latm,ac3,dca,flac,mlp,mpegaudio,opus,vorbis,h264,hevc,vp8,vp9,av1,mpeg4video,mpegvideo
flags=(
    --disable-everything --disable-autodetect --disable-network --disable-doc --disable-debug
    --disable-ffplay --disable-ffprobe --disable-avdevice
    --enable-small --enable-zlib
    --enable-protocol=file,pipe
    --enable-demuxer=$DEMUXERS --enable-decoder=$DECODERS --enable-parser=$PARSERS
    --enable-encoder=aac,mjpeg,png --enable-muxer=ipod,image2
    --enable-filter=abuffer,abuffersink,aformat,anull,aresample,atrim,buffer,buffersink,format,null,scale
)
# x86's assembly needs nasm; without it, the plain C code.
asm=true
if [[ "$(uname -m)" == x86_64 ]] && ! command -v nasm >/dev/null; then
    flags+=(--disable-x86asm)
    asm=false
fi

if command -v meson >/dev/null && command -v ninja >/dev/null && command -v pkg-config >/dev/null; then
    download "https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.bz2" "$DAV1D_SHA256" "$WORK/dav1d.tar.bz2"
    tar -xjf "$WORK/dav1d.tar.bz2" -C "$WORK"
    meson setup "$WORK/dav1d-build" "$WORK/dav1d-$DAV1D_VERSION" --prefix="$WORK/dav1d" --libdir=lib \
        --buildtype=release --default-library=static -Denable_asm=$asm \
        -Denable_tools=false -Denable_tests=false -Denable_examples=false >"$WORK/dav1d.log"
    ninja -C "$WORK/dav1d-build" install >>"$WORK/dav1d.log"
    export PKG_CONFIG_PATH="$WORK/dav1d/lib/pkgconfig"
    flags+=(--enable-libdav1d --enable-decoder=libdav1d --pkg-config-flags=--static)
else
    echo "warning: no meson, ninja or pkg-config; ffmpeg is built without AV1 video" >&2
fi

(cd "$SRC" && ./configure "${flags[@]}" >"$WORK/configure.log" && make -j"$JOBS" ffmpeg >"$WORK/make.log" 2>&1)

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$SRC/ffmpeg" "$OUT/ffmpeg"
strip "$OUT/ffmpeg"
cp "$SRC/COPYING.LGPLv2.1" "$SRC/LICENSE.md" "$OUT/"
print -r -- "FFmpeg $FFMPEG_VERSION, built by scripts/build-ffmpeg.sh from https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" >"$OUT/SOURCE.txt"
print -r -- "configure ${flags[*]}" >>"$OUT/SOURCE.txt"
if [[ -d "$WORK/dav1d" ]]; then
    cp "$WORK/dav1d-$DAV1D_VERSION/COPYING" "$OUT/COPYING.dav1d"
    print -r -- "with dav1d $DAV1D_VERSION from https://code.videolan.org/videolan/dav1d/-/archive/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.bz2" >>"$OUT/SOURCE.txt"
fi
rm -rf "$WORK"
