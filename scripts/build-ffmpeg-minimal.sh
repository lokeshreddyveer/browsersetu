#!/bin/bash
# Reproducible minimal FFmpeg + FFprobe for Browser Setu's optional media tools: LGPL only (no GPL, no non-free, no external libraries, no network), arm64 or x86_64,
# only the containers and codecs the downloader needs: join/remux WebM/Matroska/MP4/Ogg, take the sound out of a video (copy or decode), and decode to PCM for the app's own MP3 encoder.
#
#   scripts/build-ffmpeg-minimal.sh OUT_DIR [arm64|x86_64]
# Output: OUT_DIR/ffmpeg, OUT_DIR/ffprobe (single static executables, unsigned), OUT_DIR/BUILDINFO.txt (version, source hash, configure line, `ffmpeg -L` licence line).
set -euo pipefail
# Xcode's scheme actions carry build-setting variables (deployment targets, SDK names) that make clang refuse to compile; run again with a clean environment.
if [ -z "${BS_CLEAN_ENV:-}" ]; then exec /usr/bin/env -i BS_CLEAN_ENV=1 PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"} /bin/bash "$0" "$@"; fi
out="${1:?output folder}"; arch="${2:-$(uname -m)}"; [ "$arch" = "arm64" ] || arch=x86_64
VER=9.0.2; SHA=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e; URL="https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
work="$(mktemp -d)"; trap "rm -rf '$work'" EXIT
mkdir -p "$out"; curl -fsSL -o "$work/src.tar.xz" "$URL"
[ "$(shasum -a 256 "$work/src.tar.xz" | cut -d' ' -f1)" = "$SHA" ] || { echo "source archive does not match the pinned SHA-256; refusing" >&2; exit 1; }
mkdir "$work/src" && tar -xf "$work/src.tar.xz" -C "$work/src" --strip-components=1
cd "$work/src"
DEMUX=matroska,mov,ogg,mp3,flac,wav,aac,ac3,eac3,opus
MUX=matroska,webm,mp4,ipod,ogg,opus,wav,mp3,flac,null
DEC=opus,vorbis,aac,aac_fixed,mp3,mp3float,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_u8,ac3,eac3
ENC=aac,pcm_s16le,pcm_s24le,pcm_f32le,flac
PARSE=aac,aac_latm,opus,vorbis,vp8,vp9,av1,h264,hevc,mpegaudio,flac,ac3
BSF=aac_adtstoasc,extract_extradata,vp9_superframe,av1_frame_merge,h264_mp4toannexb,hevc_mp4toannexb,null,opus_metadata,setts
FILTERS=aresample,aformat,anull,null,format,atrim,trim,asetpts,setpts,volume
./configure --arch=$arch --cc=clang --extra-cflags="-mmacosx-version-min=13.0" --extra-ldflags="-mmacosx-version-min=13.0" \
  --disable-everything --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 --disable-doc --disable-debug --disable-network --disable-ffplay \
  --disable-avdevice --disable-swscale --enable-ffmpeg --enable-ffprobe --enable-static --disable-shared --enable-pic \
  --enable-protocol=file,pipe --enable-demuxer=$DEMUX --enable-muxer=$MUX --enable-decoder=$DEC --enable-encoder=$ENC --enable-parser=$PARSE --enable-bsf=$BSF --enable-filter=$FILTERS \
  > "$work/configure.log" 2>&1 || { tail -30 "$work/configure.log" >&2; exit 1; }
make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe > "$work/make.log" 2>&1 || { tail -30 "$work/make.log" >&2; exit 1; }
cp ffmpeg ffprobe "$out/"; strip -x "$out/ffmpeg" "$out/ffprobe"
{ echo "FFmpeg $VER source sha256 $SHA"; echo "arch $arch"; echo "configure: $(grep -m1 '^configuration:' <(./ffmpeg -hide_banner -version) )"; echo "license: $(./ffmpeg -hide_banner -L | head -3 | tr '\n' ' ')"; } > "$out/BUILDINFO.txt"
cp COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md "$out/" 2>/dev/null || true
