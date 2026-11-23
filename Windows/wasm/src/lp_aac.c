#include "lp_core.h"
#include "aacenc_lib.h"
#include "aacdecoder_lib.h"
#include <stdlib.h>
#include <string.h>

/* fdk-aac works on 16-bit PCM. Encode with 6 dB headroom and undo it after decoding so
   decoded overs above 0 dBFS (up to +6 dB) survive instead of clipping. */
#define HEAD 0.5f

static short q16(float v) {
    float s = v * HEAD * 32768.0f;
    if (s > 32767.0f) s = 32767.0f;
    if (s < -32768.0f) s = -32768.0f;
    return (short)(s < 0 ? s - 0.5f : s + 0.5f);
}

int lp_aac_roundtrip(const float *const *in, int channels, long frames, long rate, int bitrate,
                     float **out, long *out_frames, long *bytes) {
    if (channels < 1 || channels > 2) return -1;
    HANDLE_AACENCODER enc = NULL;
    HANDLE_AACDECODER dec = NULL;
    INT_PCM *ibuf = NULL, *dbuf = NULL;
    float *block = NULL;
    int rc = -1;
    if (aacEncOpen(&enc, 0, channels) != AACENC_OK) return -1;
    if (aacEncoder_SetParam(enc, AACENC_AOT, AOT_AAC_LC) != AACENC_OK ||
        aacEncoder_SetParam(enc, AACENC_SAMPLERATE, (UINT)rate) != AACENC_OK ||
        aacEncoder_SetParam(enc, AACENC_CHANNELMODE, channels == 1 ? MODE_1 : MODE_2) != AACENC_OK ||
        aacEncoder_SetParam(enc, AACENC_CHANNELORDER, 1) != AACENC_OK ||
        aacEncoder_SetParam(enc, AACENC_BITRATEMODE, 0) != AACENC_OK ||
        aacEncoder_SetParam(enc, AACENC_BITRATE, (UINT)bitrate) != AACENC_OK ||
        aacEncoder_SetParam(enc, AACENC_TRANSMUX, TT_MP4_RAW) != AACENC_OK ||
        aacEncoder_SetParam(enc, AACENC_AFTERBURNER, 1) != AACENC_OK) goto done;
    if (aacEncEncode(enc, NULL, NULL, NULL, NULL) != AACENC_OK) goto done;
    AACENC_InfoStruct info;
    if (aacEncInfo(enc, &info) != AACENC_OK) goto done;
    const long delay = info.nDelay;
    const int F = info.frameLength;

    dec = aacDecoder_Open(TT_MP4_RAW, 1);
    if (!dec) goto done;
    UCHAR *conf[] = { info.confBuf };
    UINT confLen[] = { info.confSize };
    if (aacDecoder_ConfigRaw(dec, conf, confLen) != AAC_DEC_OK) goto done;
    /* No decoder-side peak limiter: it would hide codec overs and add latency. */
    aacDecoder_SetParam(dec, AAC_PCM_LIMITER_ENABLE, 0);

    ibuf = malloc(sizeof(INT_PCM) * F * channels);
    const int dcap = 2048 * 8;
    dbuf = malloc(sizeof(INT_PCM) * dcap);
    block = calloc((size_t)channels * frames + 1, sizeof(float));
    if (!ibuf || !dbuf || !block) goto done;

    UCHAR pkt[8192];
    long sz = 0, pos = 0, decoded = 0;
    int eof = 0;
    while (!eof) {
        int n = 0;
        for (; n < F && pos < frames; n++, pos++)
            for (int c = 0; c < channels; c++) ibuf[n * channels + c] = q16(in[c][pos]);
        AACENC_BufDesc ib = {0}, ob = {0};
        AACENC_InArgs ia = {0};
        AACENC_OutArgs oa = {0};
        void *iptr = ibuf, *optr = pkt;
        INT iid = IN_AUDIO_DATA, isz = (INT)(sizeof(INT_PCM) * F * channels), iel = sizeof(INT_PCM);
        INT oid = OUT_BITSTREAM_DATA, osz = sizeof(pkt), oel = 1;
        ib.numBufs = 1; ib.bufs = &iptr; ib.bufferIdentifiers = &iid; ib.bufSizes = &isz; ib.bufElSizes = &iel;
        ob.numBufs = 1; ob.bufs = &optr; ob.bufferIdentifiers = &oid; ob.bufSizes = &osz; ob.bufElSizes = &oel;
        ia.numInSamples = n > 0 ? n * channels : -1;
        AACENC_ERROR e = aacEncEncode(enc, &ib, &ob, &ia, &oa);
        if (e == AACENC_ENCODE_EOF) break;
        if (e != AACENC_OK) goto done;
        if (oa.numOutBytes <= 0) continue;
        sz += oa.numOutBytes;
        UCHAR *pp = pkt;
        UINT plen = (UINT)oa.numOutBytes, valid = plen;
        if (aacDecoder_Fill(dec, &pp, &plen, &valid) != AAC_DEC_OK) goto done;
        AAC_DECODER_ERROR de = aacDecoder_DecodeFrame(dec, dbuf, dcap, 0);
        if (de != AAC_DEC_OK) continue;
        CStreamInfo *si = aacDecoder_GetStreamInfo(dec);
        int och = si->numChannels, ofr = si->frameSize;
        const long d = delay + (long)si->outputDelay;
        for (int i = 0; i < ofr; i++, decoded++) {
            long s = decoded - d;
            if (s < 0 || s >= frames) continue;
            for (int c = 0; c < channels; c++) {
                int sc = c < och ? c : och - 1;
                block[(size_t)c * frames + s] = dbuf[i * och + sc] / (32768.0f * HEAD);
            }
        }
        if (decoded - delay - (long)si->outputDelay >= frames) eof = 1;
    }
    *out = block; block = NULL;
    *out_frames = frames;
    *bytes = sz;
    rc = 0;
done:
    free(ibuf); free(dbuf); free(block);
    if (dec) aacDecoder_Close(dec);
    if (enc) aacEncClose(&enc);
    return rc;
}
