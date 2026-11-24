#ifndef COPUS_H
#define COPUS_H

// A small C face over libopus, for the PlayFX engine: Swift can't call opus_encoder_ctl (it's variadic), and the
// libopus that's linked into StreamCore (the static one libchiaki brings) is all the engine needs, so this target
// declares the handful of libopus functions it calls itself (copus.c) instead of depending on the library's headers
// and a pkg-config lookup that could pick a second, dynamic libopus.

#ifdef __cplusplus
extern "C" {
#endif

/// A decoder for the console's Opus packets (libopus's OpusDecoder).
typedef struct copus_decoder copus_decoder;
/// An encoder for the microphone (libopus's OpusEncoder).
typedef struct copus_encoder copus_encoder;

/// Makes a decoder for `channels` (1 or 2) at `sampleRate` (8000, 12000, 16000, 24000 or 48000); NULL on failure.
copus_decoder *copus_decoder_create(int sampleRate, int channels);
/// Decodes one packet (`length` bytes at `data`) into `pcm`, which holds `capacityFrames` frames of interleaved
/// signed 16-bit samples. With `data` NULL it conceals a lost packet instead (packet-loss concealment) and
/// `capacityFrames` is the number of frames to make (a multiple of 2.5 ms). Returns the frames written, or a
/// negative libopus error.
int copus_decode(copus_decoder *decoder, const unsigned char *data, int length, short *pcm, int capacityFrames);
/// Forgets everything the decoder learned (after a gap it didn't conceal).
void copus_decoder_reset(copus_decoder *decoder);
void copus_decoder_destroy(copus_decoder *decoder);

/// Makes the microphone's encoder (av.md section 8.2): `channels` at `sampleRate`, restricted low delay (CELT only),
/// constant `bitrate` bit/s, signal type music, phase inversion off. NULL on failure.
copus_encoder *copus_encoder_create(int sampleRate, int channels, int bitrate);
/// Encodes `frames` frames (per channel) of interleaved signed 16-bit samples into `out` (`capacity` bytes).
/// Returns the packet's length, or a negative libopus error.
int copus_encode(copus_encoder *encoder, const short *pcm, int frames, unsigned char *out, int capacity);
void copus_encoder_destroy(copus_encoder *encoder);

#ifdef __cplusplus
}
#endif

#endif
