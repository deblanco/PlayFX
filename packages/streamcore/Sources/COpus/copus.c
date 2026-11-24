#include "copus.h"

// The libopus entry points used here, declared as libopus's public API documents them (opus.h, opus_defines.h).
typedef struct OpusDecoder OpusDecoder;
typedef struct OpusEncoder OpusEncoder;
extern OpusDecoder *opus_decoder_create(int Fs, int channels, int *error);
extern int opus_decode(OpusDecoder *st, const unsigned char *data, int len, short *pcm, int frame_size, int decode_fec);
extern int opus_decoder_ctl(OpusDecoder *st, int request, ...);
extern void opus_decoder_destroy(OpusDecoder *st);
extern OpusEncoder *opus_encoder_create(int Fs, int channels, int application, int *error);
extern int opus_encode(OpusEncoder *st, const short *pcm, int frame_size, unsigned char *data, int max_data_bytes);
extern int opus_encoder_ctl(OpusEncoder *st, int request, ...);
extern void opus_encoder_destroy(OpusEncoder *st);

enum {
    kOK = 0,
    kApplicationRestrictedLowDelay = 2051,
    kSignalMusic = 3002,
    kSetBitrate = 4002,
    kSetVBR = 4006,
    kSetSignal = 4024,
    kResetState = 4028,
    kSetPhaseInversionDisabled = 4046,
};

copus_decoder *copus_decoder_create(int sampleRate, int channels) {
    int error = kOK;
    OpusDecoder *decoder = opus_decoder_create(sampleRate, channels, &error);
    return error == kOK ? (copus_decoder *)decoder : (copus_decoder *)0;
}

int copus_decode(copus_decoder *decoder, const unsigned char *data, int length, short *pcm, int capacityFrames) {
    return opus_decode((OpusDecoder *)decoder, data, data ? length : 0, pcm, capacityFrames, 0);
}

void copus_decoder_reset(copus_decoder *decoder) { opus_decoder_ctl((OpusDecoder *)decoder, kResetState); }

void copus_decoder_destroy(copus_decoder *decoder) { opus_decoder_destroy((OpusDecoder *)decoder); }

copus_encoder *copus_encoder_create(int sampleRate, int channels, int bitrate) {
    int error = kOK;
    OpusEncoder *encoder = opus_encoder_create(sampleRate, channels, kApplicationRestrictedLowDelay, &error);
    if (error != kOK || !encoder) return (copus_encoder *)0;
    if (opus_encoder_ctl(encoder, kSetBitrate, (int)bitrate) != kOK || opus_encoder_ctl(encoder, kSetVBR, 0) != kOK
        || opus_encoder_ctl(encoder, kSetSignal, kSignalMusic) != kOK
        || opus_encoder_ctl(encoder, kSetPhaseInversionDisabled, 1) != kOK) {
        opus_encoder_destroy(encoder);
        return (copus_encoder *)0;
    }
    return (copus_encoder *)encoder;
}

int copus_encode(copus_encoder *encoder, const short *pcm, int frames, unsigned char *out, int capacity) {
    return opus_encode((OpusEncoder *)encoder, pcm, frames, out, capacity);
}

void copus_encoder_destroy(copus_encoder *encoder) { opus_encoder_destroy((OpusEncoder *)encoder); }
