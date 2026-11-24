#include "copus.h"

// libopus's own headers, from the keg Package.swift links (OPUS_PREFIX/include/opus).
#include <opus.h>

copus_decoder *copus_decoder_create(int sampleRate, int channels) {
    int error = OPUS_OK;
    OpusDecoder *decoder = opus_decoder_create(sampleRate, channels, &error);
    return error == OPUS_OK ? (copus_decoder *)decoder : (copus_decoder *)0;
}

int copus_decode(copus_decoder *decoder, const unsigned char *data, int length, short *pcm, int capacityFrames) {
    return opus_decode((OpusDecoder *)decoder, data, data ? length : 0, pcm, capacityFrames, 0);
}

void copus_decoder_reset(copus_decoder *decoder) { opus_decoder_ctl((OpusDecoder *)decoder, OPUS_RESET_STATE); }

void copus_decoder_destroy(copus_decoder *decoder) { opus_decoder_destroy((OpusDecoder *)decoder); }

copus_encoder *copus_encoder_create(int sampleRate, int channels, int bitrate) {
    int error = OPUS_OK;
    OpusEncoder *encoder = opus_encoder_create(sampleRate, channels, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &error);
    if (error != OPUS_OK || !encoder) return (copus_encoder *)0;
    if (opus_encoder_ctl(encoder, OPUS_SET_BITRATE(bitrate)) != OPUS_OK || opus_encoder_ctl(encoder, OPUS_SET_VBR(0)) != OPUS_OK
        || opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC)) != OPUS_OK
        || opus_encoder_ctl(encoder, OPUS_SET_PHASE_INVERSION_DISABLED(1)) != OPUS_OK) {
        opus_encoder_destroy(encoder);
        return (copus_encoder *)0;
    }
    return (copus_encoder *)encoder;
}

int copus_encode(copus_encoder *encoder, const short *pcm, int frames, unsigned char *out, int capacity) {
    return opus_encode((OpusEncoder *)encoder, pcm, frames, out, capacity);
}

void copus_encoder_destroy(copus_encoder *encoder) { opus_encoder_destroy((OpusEncoder *)encoder); }
