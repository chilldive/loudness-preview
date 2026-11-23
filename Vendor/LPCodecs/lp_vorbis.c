#include "lp_codecs.h"
#include <vorbis/vorbisenc.h>
#include <stdlib.h>
#include <string.h>

void lp_free(void *p) { free(p); }

static int grow(float ***bufs, int channels, long *cap, long need) {
    if (need <= *cap) return 0;
    long nc = *cap * 2 > need ? *cap * 2 : need;
    for (int c = 0; c < channels; c++) {
        float *p = realloc((*bufs)[c], nc * sizeof(float));
        if (!p) return -1;
        (*bufs)[c] = p;
    }
    *cap = nc;
    return 0;
}

int lp_vorbis_roundtrip(const float *const *in, int channels, long frames, long rate,
                        float quality, float **out, long *out_frames, long *bytes) {
    int rc = -1;
    vorbis_info vi, di;
    vorbis_comment vc, dc;
    vorbis_dsp_state vd, dd;
    vorbis_block vb, db;
    vorbis_info_init(&vi);
    vorbis_info_init(&di);
    vorbis_comment_init(&vc);
    vorbis_comment_init(&dc);
    if (vorbis_encode_init_vbr(&vi, channels, rate, quality) != 0) goto done_info;

    vorbis_analysis_init(&vd, &vi);
    vorbis_block_init(&vd, &vb);

    ogg_packet h0, h1, h2;
    vorbis_analysis_headerout(&vd, &vc, &h0, &h1, &h2);
    if (vorbis_synthesis_headerin(&di, &dc, &h0) || vorbis_synthesis_headerin(&di, &dc, &h1) ||
        vorbis_synthesis_headerin(&di, &dc, &h2)) goto done_enc;
    vorbis_synthesis_init(&dd, &di);
    vorbis_block_init(&dd, &db);

    long cap = frames + 8192, w = 0, total = 0;
    float **bufs = calloc(channels, sizeof(float *));
    for (int c = 0; c < channels; c++) bufs[c] = malloc(cap * sizeof(float));

    long pos = 0;
    int eos = 0;
    while (!eos) {
        if (pos < frames) {
            long n = frames - pos < 1024 ? frames - pos : 1024;
            float **b = vorbis_analysis_buffer(&vd, (int)n);
            for (int c = 0; c < channels; c++) memcpy(b[c], in[c] + pos, n * sizeof(float));
            vorbis_analysis_wrote(&vd, (int)n);
            pos += n;
        } else {
            vorbis_analysis_wrote(&vd, 0);
            eos = 1;
        }
        while (vorbis_analysis_blockout(&vd, &vb) == 1) {
            vorbis_analysis(&vb, NULL);
            vorbis_bitrate_addblock(&vb);
            ogg_packet op;
            while (vorbis_bitrate_flushpacket(&vd, &op)) {
                total += op.bytes;
                if (vorbis_synthesis(&db, &op) == 0) vorbis_synthesis_blockin(&dd, &db);
                float **pcm;
                int got;
                while ((got = vorbis_synthesis_pcmout(&dd, &pcm)) > 0) {
                    if (grow(&bufs, channels, &cap, w + got)) goto done_all;
                    for (int c = 0; c < channels; c++) memcpy(bufs[c] + w, pcm[c], got * sizeof(float));
                    w += got;
                    vorbis_synthesis_read(&dd, got);
                }
            }
        }
    }

    float *block = malloc((size_t)channels * (w > 0 ? w : 1) * sizeof(float));
    if (block) {
        for (int c = 0; c < channels; c++) memcpy(block + (size_t)c * w, bufs[c], w * sizeof(float));
        *out = block;
        *out_frames = w;
        *bytes = total;
        rc = 0;
    }

done_all:
    for (int c = 0; c < channels; c++) free(bufs[c]);
    free(bufs);
    vorbis_block_clear(&db);
    vorbis_dsp_clear(&dd);
done_enc:
    vorbis_block_clear(&vb);
    vorbis_dsp_clear(&vd);
done_info:
    vorbis_comment_clear(&vc);
    vorbis_comment_clear(&dc);
    vorbis_info_clear(&vi);
    vorbis_info_clear(&di);
    return rc;
}
