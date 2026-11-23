#ifndef LP_CORE_H
#define LP_CORE_H
#include "lp_codecs.h"
/* All planar outputs are a single malloc'd block [channels * frames]; free with lp_free. */
void *lp_malloc(long n);
int lp_aac_roundtrip(const float *const *in, int channels, long frames, long rate, int bitrate,
                     float **out, long *out_frames, long *bytes);
int lp_resample(const float *const *in, int channels, long frames, long from, long to,
                float **out, long *out_frames);
double lp_integrated(const float *const *in, int channels, long frames, double fs);
float lp_sample_peak(const float *const *in, int channels, long frames);
float lp_true_peak(const float *const *in, int channels, long frames, double fs);
float *lp_limiter_envelope(const float *const *in, int channels, long frames, double gain_db, double fs);
void lp_waveform(const float *const *in, int channels, long frames, int buckets, float *out);
long lp_align_lag(const float *const *x, int xch, long xn, const float *const *ref, int rch, long rn);
#endif
