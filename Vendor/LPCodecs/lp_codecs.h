#ifndef LP_CODECS_H
#define LP_CODECS_H
/// Encode planar float PCM to Vorbis (VBR quality) and decode it back in memory.
/// On success returns 0; *out is a malloc'd planar block [channels * out_frames].
int lp_vorbis_roundtrip(const float *const *in, int channels, long frames, long rate,
                        float quality, float **out, long *out_frames, long *bytes);
/// Encode 48 kHz planar float PCM with libopus (VBR, given bitrate, 20 ms frames) and decode it back.
int lp_opus_roundtrip(const float *const *in, int channels, long frames, int bitrate,
                      float **out, long *out_frames, long *bytes);
void lp_free(void *p);
#endif
