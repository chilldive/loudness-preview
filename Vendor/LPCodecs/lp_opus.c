#include "lp_codecs.h"
#include <opus.h>
#include <stdlib.h>
#include <string.h>

int lp_opus_roundtrip(const float *const *in, int channels, long frames, int bitrate,
                      float **out, long *out_frames, long *bytes) {
    int err = 0;
    OpusEncoder *enc = opus_encoder_create(48000, channels, OPUS_APPLICATION_AUDIO, &err);
    if (err != OPUS_OK || !enc) return -1;
    OpusDecoder *dec = opus_decoder_create(48000, channels, &err);
    if (err != OPUS_OK || !dec) { opus_encoder_destroy(enc); return -1; }
    opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
    opus_encoder_ctl(enc, OPUS_SET_VBR(1));
    opus_encoder_ctl(enc, OPUS_SET_COMPLEXITY(10));
    opus_encoder_ctl(enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
    opus_int32 lookahead = 0;
    opus_encoder_ctl(enc, OPUS_GET_LOOKAHEAD(&lookahead));

    const int F = 960;
    long total = frames + lookahead;
    long nFrames = (total + F - 1) / F;
    float *ibuf = malloc(sizeof(float) * F * channels);
    float *obuf = malloc(sizeof(float) * F * channels);
    float *block = calloc((size_t)channels * frames + 1, sizeof(float));
    unsigned char pkt[4000];
    long written = 0, sz = 0;
    int rc = -1;
    if (!ibuf || !obuf || !block) goto done;

    for (long f = 0; f < nFrames; f++) {
        for (int i = 0; i < F; i++) {
            long s = f * F + i;
            for (int c = 0; c < channels; c++) ibuf[i * channels + c] = s < frames ? in[c][s] : 0.0f;
        }
        int n = opus_encode_float(enc, ibuf, F, pkt, sizeof(pkt));
        if (n < 0) goto done;
        sz += n;
        int got = opus_decode_float(dec, pkt, n, obuf, F, 0);
        if (got < 0) goto done;
        for (int i = 0; i < got; i++) {
            long s = f * F + i - lookahead;   // drop pre-skip
            if (s < 0 || s >= frames) continue;
            for (int c = 0; c < channels; c++) block[(size_t)c * frames + s] = obuf[i * channels + c];
            written = s + 1;
        }
    }
    *out = block;
    *out_frames = frames;
    *bytes = sz;
    block = NULL;
    rc = 0;
done:
    free(ibuf); free(obuf); free(block);
    opus_encoder_destroy(enc);
    opus_decoder_destroy(dec);
    (void)written;
    return rc;
}
