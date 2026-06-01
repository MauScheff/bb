#!/usr/bin/env bash
set -euo pipefail

OPUS_VERSION="${OPUS_VERSION:-1.6.1}"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-13.0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/Vendor/Opus}"
XCFRAMEWORK="${OUTPUT_DIR}/TurboOpus.xcframework"
WORK_DIR="${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/turbo-libopus.XXXXXX")}"

cleanup() {
  if [[ "${KEEP_TURBO_OPUS_BUILD:-0}" != "1" ]]; then
    rm -rf "${WORK_DIR}"
  else
    echo "Keeping build directory: ${WORK_DIR}" >&2
  fi
}
trap cleanup EXIT

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

require_tool curl
require_tool cmake
require_tool xcrun
require_tool xcodebuild
require_tool shasum
require_tool lipo

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

TARBALL="${WORK_DIR}/opus-${OPUS_VERSION}.tar.gz"
SOURCE_DIR="${WORK_DIR}/opus-${OPUS_VERSION}"

echo "Downloading ${OPUS_URL}" >&2
curl -L --fail --silent --show-error -o "${TARBALL}" "${OPUS_URL}"
ACTUAL_SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA256}" != "${OPUS_SHA256}" ]]; then
  echo "SHA-256 mismatch for ${TARBALL}" >&2
  echo "expected ${OPUS_SHA256}" >&2
  echo "actual   ${ACTUAL_SHA256}" >&2
  exit 1
fi

tar -xzf "${TARBALL}" -C "${WORK_DIR}"

HEADERS_DIR="${WORK_DIR}/TurboOpusHeaders"
mkdir -p "${HEADERS_DIR}/opus"
cp "${SOURCE_DIR}/include/"*.h "${HEADERS_DIR}/opus/"

cat >"${HEADERS_DIR}/TurboOpus.h" <<'HEADER'
#ifndef TURBO_OPUS_H
#define TURBO_OPUS_H

#include <stdint.h>
#include <opus/opus.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t TurboOpusEncoderSetBitrate(OpusEncoder *encoder, int32_t bitrate);
int32_t TurboOpusEncoderSetComplexity(OpusEncoder *encoder, int32_t complexity);
int32_t TurboOpusEncoderSetInBandFEC(OpusEncoder *encoder, int32_t enabled);
int32_t TurboOpusEncoderSetLSBDepth(OpusEncoder *encoder, int32_t bitDepth);
int32_t TurboOpusEncoderSetPacketLossPercent(OpusEncoder *encoder, int32_t percent);
int32_t TurboOpusEncoderSetSignalVoice(OpusEncoder *encoder);
int32_t TurboOpusEncoderSetVBR(OpusEncoder *encoder, int32_t enabled);
int32_t TurboOpusEncoderSetVBRConstraint(OpusEncoder *encoder, int32_t enabled);
int32_t TurboOpusEncoderSetDTX(OpusEncoder *encoder, int32_t enabled);
int32_t TurboOpusEncoderSetBandwidthFullband(OpusEncoder *encoder);
int32_t TurboOpusEncoderSetMaxBandwidthFullband(OpusEncoder *encoder);
const char *TurboOpusErrorString(int32_t error);
const char *TurboOpusVersionString(void);

#ifdef __cplusplus
}
#endif

#endif
HEADER

cat >"${HEADERS_DIR}/module.modulemap" <<'MODULEMAP'
module TurboOpus {
  header "TurboOpus.h"
  export *
}
MODULEMAP

SHIM_SOURCE="${WORK_DIR}/TurboOpusShim.c"
cat >"${SHIM_SOURCE}" <<'SHIM'
#include "TurboOpus.h"

int32_t TurboOpusEncoderSetBitrate(OpusEncoder *encoder, int32_t bitrate) {
    return opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate));
}

int32_t TurboOpusEncoderSetComplexity(OpusEncoder *encoder, int32_t complexity) {
    return opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(complexity));
}

int32_t TurboOpusEncoderSetInBandFEC(OpusEncoder *encoder, int32_t enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_INBAND_FEC(enabled));
}

int32_t TurboOpusEncoderSetLSBDepth(OpusEncoder *encoder, int32_t bitDepth) {
    return opus_encoder_ctl(encoder, OPUS_SET_LSB_DEPTH(bitDepth));
}

int32_t TurboOpusEncoderSetPacketLossPercent(OpusEncoder *encoder, int32_t percent) {
    return opus_encoder_ctl(encoder, OPUS_SET_PACKET_LOSS_PERC(percent));
}

int32_t TurboOpusEncoderSetSignalVoice(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int32_t TurboOpusEncoderSetVBR(OpusEncoder *encoder, int32_t enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_VBR(enabled));
}

int32_t TurboOpusEncoderSetVBRConstraint(OpusEncoder *encoder, int32_t enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_VBR_CONSTRAINT(enabled));
}

int32_t TurboOpusEncoderSetDTX(OpusEncoder *encoder, int32_t enabled) {
    return opus_encoder_ctl(encoder, OPUS_SET_DTX(enabled));
}

int32_t TurboOpusEncoderSetBandwidthFullband(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_SET_BANDWIDTH(OPUS_BANDWIDTH_FULLBAND));
}

int32_t TurboOpusEncoderSetMaxBandwidthFullband(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_SET_MAX_BANDWIDTH(OPUS_BANDWIDTH_FULLBAND));
}

const char *TurboOpusErrorString(int32_t error) {
    return opus_strerror(error);
}

const char *TurboOpusVersionString(void) {
    return opus_get_version_string();
}
SHIM

build_arch() {
  local sdk="$1"
  local arch="$2"
  local build_dir="${WORK_DIR}/build-${sdk}-${arch}"
  local output_lib="${WORK_DIR}/libTurboOpus-${sdk}-${arch}.a"
  local sdk_path
  local min_version_flag

  sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  if [[ "${sdk}" == "iphoneos" ]]; then
    min_version_flag="-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
  else
    min_version_flag="-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
  fi

  echo "Building libopus ${OPUS_VERSION} for ${sdk}/${arch}" >&2
  cmake -S "${SOURCE_DIR}" -B "${build_dir}" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${sdk_path}" \
    -DCMAKE_OSX_ARCHITECTURES="${arch}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DOPUS_BUILD_SHARED_LIBRARY=OFF \
    -DOPUS_BUILD_TESTING=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_INSTALL_PKG_CONFIG_MODULE=OFF \
    -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=OFF >/dev/null
  cmake --build "${build_dir}" --config Release --target opus -j "$(sysctl -n hw.ncpu)" >/dev/null

  xcrun --sdk "${sdk}" clang \
    -arch "${arch}" \
    -isysroot "${sdk_path}" \
    "${min_version_flag}" \
    -I"${HEADERS_DIR}" \
    -I"${SOURCE_DIR}/include" \
    -Os \
    -fvisibility=hidden \
    -c "${SHIM_SOURCE}" \
    -o "${build_dir}/TurboOpusShim.o"

  /usr/bin/libtool -static -o "${output_lib}" "${build_dir}/libopus.a" "${build_dir}/TurboOpusShim.o" >/dev/null
}

build_arch iphoneos arm64
build_arch iphonesimulator arm64
build_arch iphonesimulator x86_64

lipo -create \
  "${WORK_DIR}/libTurboOpus-iphonesimulator-arm64.a" \
  "${WORK_DIR}/libTurboOpus-iphonesimulator-x86_64.a" \
  -output "${WORK_DIR}/libTurboOpus-iphonesimulator.a"

rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
  -library "${WORK_DIR}/libTurboOpus-iphoneos-arm64.a" -headers "${HEADERS_DIR}" \
  -library "${WORK_DIR}/libTurboOpus-iphonesimulator.a" -headers "${HEADERS_DIR}" \
  -output "${XCFRAMEWORK}" >/dev/null

cp "${SOURCE_DIR}/COPYING" "${OUTPUT_DIR}/LICENSE.opus.txt"

echo "Built ${XCFRAMEWORK}" >&2
