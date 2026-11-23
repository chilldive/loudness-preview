#include "lp_core.h"
#include "speex_resampler.h"
#include <stdlib.h>
#include <math.h>

int lp_resample(const float *const *in, int channels, long frames, long from, long to,
                float **out, long *out_frames) {
    long want = lround((double)frames * to / from);
    float *block = calloc((size_t)channels * want + 1, sizeof(float));
    if (!block) return -1;
    int err = 0;
    SpeexResamplerState *st = speex_resampler_init(channels, (spx_uint32_t)from, (spx_uint32_t)to, 10, &err);
    if (!st || err) { free(block); return -1; }
    speex_resampler_skip_zeros(st);
    long lat = speex_resampler_get_input_latency(st);
    static const float zeros[4096];
    for (int c = 0; c < channels; c++) {
        long ip = 0, op = 0, total = frames + lat + 16;
        float *dst = block + (size_t)c * want;
        while (op < want && ip < total) {
            spx_uint32_t ilen, olen = (spx_uint32_t)(want - op);
            if (olen > 1 << 20) olen = 1 << 20;
            const float *src;
            if (ip < frames) {
                long r = frames - ip; if (r > (1 << 20)) r = 1 << 20;
                ilen = (spx_uint32_t)r; src = in[c] + ip;
            } else {
                long r = total - ip; if (r > 4096) r = 4096;
                ilen = (spx_uint32_t)r; src = zeros;
            }
            speex_resampler_process_float(st, c, src, &ilen, dst + op, &olen);
            ip += ilen; op += olen;
            if (ilen == 0 && olen == 0) break;
        }
    }
    speex_resampler_destroy(st);
    *out = block;
    *out_frames = want;
    return 0;
}
