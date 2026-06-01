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
