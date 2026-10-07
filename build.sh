#!/usr/bin/env bash
#
# Builds the Media3 FFmpeg audio decoder extension as an AAR for armeabi-v7a,
# arm64-v8a, x86 and x86_64, with FFmpeg in its default LGPL v2.1+ configuration.
#
# Usage:   ./build.sh [version]     (default version: <Media3 version>-dev)
# Needs:   Linux, git, make, unzip, a JDK (17 or newer) and an Android SDK with
#          its command line tools (ANDROID_HOME).
# Output:  out/media3-ffmpeg-decoder-<version>.aar
#          out/media3-ffmpeg-decoder-<version>.aar.sha256
#          out/BUILD_INFO.txt
#
# The steps are the ones in the README of Media3's libraries/decoder_ffmpeg, and
# the FFmpeg configure flags are those of Media3's own build_ffmpeg.sh, both at
# the pinned Media3 tag. What is pinned stands in versions.env.

set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/versions.env"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

: "${ANDROID_HOME:?Set ANDROID_HOME to the path of an Android SDK}"

VERSION="${1:-${MEDIA3_VERSION}-dev}"
[[ "${VERSION}" == "${MEDIA3_VERSION}-"* ]] ||
  die "Version ${VERSION} does not start with ${MEDIA3_VERSION}- (the pinned Media3 version)"

ABIS=(armeabi-v7a arm64-v8a x86 x86_64)
# Aligns the JNI library for devices with 16 KB memory pages. Needed for
# arm64-v8a and x86_64; NDK r26 still aligns to 4 KB by default.
JNI_LINKER_FLAGS="-Wl,-z,max-page-size=16384"

WORK="${ROOT}/work"
OUT="${ROOT}/out"
MEDIA3="${WORK}/media"
FFMPEG="${MEDIA3}/libraries/decoder_ffmpeg/src/main/jni/ffmpeg"
NDK="${ANDROID_HOME}/ndk/${NDK_VERSION}"
TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin"
AAR_NAME="media3-ffmpeg-decoder-${VERSION}.aar"
CONFIGURE_LOG="${WORK}/configure-flags.txt"

rm -rf "${WORK}" "${OUT}"
mkdir -p "${WORK}" "${OUT}"

# ---------------------------------------------------------------------------
log "Installing NDK ${NDK_VERSION} and CMake ${CMAKE_VERSION} if missing"

if [[ ! -d "${NDK}" || ! -d "${ANDROID_HOME}/cmake/${CMAKE_VERSION}" ]]; then
  "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" \
    "ndk;${NDK_VERSION}" "cmake;${CMAKE_VERSION}"
fi
[[ -x "${TOOLCHAIN}/clang" ]] || die "No NDK toolchain in ${TOOLCHAIN}"

# ---------------------------------------------------------------------------
log "Fetching Media3 ${MEDIA3_VERSION} and FFmpeg ${FFMPEG_BRANCH}"

# fetch <repository> <commit> <directory>: checks out exactly one commit.
fetch() {
  mkdir -p "$3"
  git -C "$3" init --quiet
  git -C "$3" remote add origin "$1"
  git -C "$3" fetch --quiet --depth 1 origin "$2"
  git -C "$3" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
}

fetch https://github.com/androidx/media.git "${MEDIA3_COMMIT}" "${MEDIA3}"
# GitHub hosts FFmpeg's official mirror of https://git.ffmpeg.org/ffmpeg.git.
# The commit id is the same in both.
fetch https://github.com/FFmpeg/FFmpeg.git "${FFMPEG_COMMIT}" "${FFMPEG}"

# ---------------------------------------------------------------------------
# FFmpeg, once per ABI, as static libraries in ffmpeg/android-libs/<abi>.

COMMON_FLAGS=(
  --target-os=android
  --enable-static
  --disable-shared
  --disable-doc
  --disable-programs
  --disable-everything
  --disable-avdevice
  --disable-avformat
  --disable-swscale
  --disable-postproc
  --disable-avfilter
  --disable-symver
  --enable-swresample
  --extra-ldexeflags=-pie
  --disable-v4l2-m2m
  --disable-vulkan
  --nm="${TOOLCHAIN}/llvm-nm"
  --ar="${TOOLCHAIN}/llvm-ar"
  --ranlib="${TOOLCHAIN}/llvm-ranlib"
  --strip="${TOOLCHAIN}/llvm-strip"
)
for decoder in ${DECODERS}; do
  COMMON_FLAGS+=("--enable-decoder=${decoder}")
done
EXPECTED_CODECS="$(printf '%s_decoder\n' ${DECODERS} | sort | xargs)"

# build_ffmpeg <abi> <configure flags for that ABI...>
build_ffmpeg() {
  local abi="$1"
  shift
  log "Building FFmpeg for ${abi}"

  ./configure --libdir="android-libs/${abi}" "$@" "${COMMON_FLAGS[@]}"

  # Stop if the result is not what this repository promises.
  grep -x '#define FFMPEG_LICENSE "LGPL version 2.1 or later"' config.h > /dev/null ||
    die "${abi}: FFmpeg is not configured as LGPL version 2.1 or later"
  local codecs
  codecs="$(sed -n 's/^ *&ff_\(.*\),$/\1/p' libavcodec/codec_list.c | sort | xargs)"
  [[ "${codecs}" == "${EXPECTED_CODECS}" ]] ||
    die "${abi}: FFmpeg would be built with '${codecs}', expected '${EXPECTED_CODECS}'"

  # The flags exactly as FFmpeg recorded them, one per line.
  {
    echo
    echo "FFmpeg configure flags, ${abi}:"
    sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' config.h |
      sed 's/ --/\n--/g' | sed 's/^/  /'
  } >> "${CONFIGURE_LOG}"

  make -j"$(nproc)"
  make install-libs
  make clean
}

cd "${FFMPEG}"

build_ffmpeg armeabi-v7a \
  --arch=arm \
  --cpu=armv7-a \
  --cross-prefix="${TOOLCHAIN}/armv7a-linux-androideabi${ANDROID_API}-" \
  --extra-cflags="-march=armv7-a -mfloat-abi=softfp" \
  --extra-ldflags="-Wl,--fix-cortex-a8"

build_ffmpeg arm64-v8a \
  --arch=aarch64 \
  --cpu=armv8-a \
  --cross-prefix="${TOOLCHAIN}/aarch64-linux-android${ANDROID_API}-"

build_ffmpeg x86 \
  --arch=x86 \
  --cpu=i686 \
  --cross-prefix="${TOOLCHAIN}/i686-linux-android${ANDROID_API}-" \
  --disable-asm

build_ffmpeg x86_64 \
  --arch=x86_64 \
  --cpu=x86-64 \
  --cross-prefix="${TOOLCHAIN}/x86_64-linux-android${ANDROID_API}-" \
  --disable-asm

# ---------------------------------------------------------------------------
log "Building the AAR of Media3's FFmpeg decoder module"

cd "${MEDIA3}"
./gradlew --no-daemon --console=plain \
  --init-script "${ROOT}/media3-ffmpeg.init.gradle" \
  -PffmpegNdkVersion="${NDK_VERSION}" \
  -PffmpegAbis="$(IFS=,; echo "${ABIS[*]}")" \
  -PffmpegLinkerFlags="${JNI_LINKER_FLAGS}" \
  :lib-decoder-ffmpeg:assembleRelease

BUILT_AAR="$(find "${MEDIA3}/libraries/decoder_ffmpeg" -name '*-release.aar')"
[[ -f "${BUILT_AAR}" ]] || die "Expected exactly one release AAR, found: '${BUILT_AAR}'"
cp "${BUILT_AAR}" "${OUT}/${AAR_NAME}"

# ---------------------------------------------------------------------------
log "Checking the AAR"

unzip -q "${OUT}/${AAR_NAME}" -d "${WORK}/aar"

unzip -l "${WORK}/aar/classes.jar" |
  grep 'androidx/media3/decoder/ffmpeg/FfmpegAudioRenderer.class' > /dev/null ||
  die "classes.jar does not hold FfmpegAudioRenderer"

LIBRARIES=""
for abi in "${ABIS[@]}"; do
  library="${WORK}/aar/jni/${abi}/libffmpegJNI.so"
  [[ -f "${library}" ]] || die "${abi}: no libffmpegJNI.so in the AAR"

  # Alignment of the loadable segments. 0x4000 is 16 KB.
  alignment="$("${TOOLCHAIN}/llvm-readelf" --program-headers --wide "${library}" |
    awk '$1 == "LOAD" { print $NF }' | sort -u | xargs)"
  if [[ "${abi}" == *64* && "${alignment}" != "0x4000" ]]; then
    die "${abi}: segments are aligned to ${alignment}, not to 0x4000 (16 KB)"
  fi
  LIBRARIES+="  jni/${abi}/libffmpegJNI.so: $(stat -c %s "${library}") bytes, segment alignment ${alignment}"$'\n'
done

# ---------------------------------------------------------------------------
log "Writing the checksum and BUILD_INFO.txt"

cd "${OUT}"
sha256sum "${AAR_NAME}" > "${AAR_NAME}.sha256"

cat > BUILD_INFO.txt <<EOF
${AAR_NAME}

Media3 (Apache License 2.0)
  Tag:      ${MEDIA3_VERSION}
  Commit:   ${MEDIA3_COMMIT}
  Source:   https://github.com/androidx/media
  Module:   libraries/decoder_ffmpeg

FFmpeg (GNU Lesser General Public License, version 2.1 or later)
  Branch:   ${FFMPEG_BRANCH} (RELEASE file: $(cat "${FFMPEG}/RELEASE"))
  Commit:   ${FFMPEG_COMMIT}
  Source:   https://git.ffmpeg.org/ffmpeg.git
            https://github.com/FFmpeg/FFmpeg/tree/${FFMPEG_COMMIT}
  Decoders: ${DECODERS}

Toolchain
  Android NDK:        ${NDK_RELEASE} (${NDK_VERSION})
  Android API level:  ${ANDROID_API}
  ABIs:               ${ABIS[*]}
  JNI linker flags:   ${JNI_LINKER_FLAGS}

Build scripts
  Commit:   $(git -C "${ROOT}" rev-parse HEAD 2> /dev/null || echo unknown)

Native libraries
${LIBRARIES}$(cat "${CONFIGURE_LOG}")
EOF

cat BUILD_INFO.txt
log "Done: ${OUT}/${AAR_NAME}"
cat "${AAR_NAME}.sha256"
