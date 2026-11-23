/* C port of Sources/DSP.swift (Loudness / Processing). Keep the two in step. */
#include "lp_core.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>


#ifdef __wasm_simd128__
#include <wasm_simd128.h>
static inline float dot(const float *a, const float *b, long n) {
    v128_t s0 = wasm_f32x4_splat(0), s1 = s0;
    long k = 0;
    for (; k + 8 <= n; k += 8) {
        s0 = wasm_f32x4_add(s0, wasm_f32x4_mul(wasm_v128_load(a + k), wasm_v128_load(b + k)));
        s1 = wasm_f32x4_add(s1, wasm_f32x4_mul(wasm_v128_load(a + k + 4), wasm_v128_load(b + k + 4)));
    }
    s0 = wasm_f32x4_add(s0, s1);
    float acc = wasm_f32x4_extract_lane(s0, 0) + wasm_f32x4_extract_lane(s0, 1)
              + wasm_f32x4_extract_lane(s0, 2) + wasm_f32x4_extract_lane(s0, 3);
    for (; k < n; k++) acc += a[k] * b[k];
    return acc;
}
#else
static inline float dot(const float *a, const float *b, long n) {
    float acc = 0;
    for (long k = 0; k < n; k++) acc += a[k] * b[k];
    return acc;
}
#endif

void *lp_malloc(long n) { return malloc((size_t)n); }

/* ITU-R BS.1770-4 integrated loudness */
double lp_integrated(const float *const *chs, int nCh, long n, double fs) {
    if (nCh <= 0) return -INFINITY;
    double weights[8];
    for (int c = 0; c < nCh && c < 8; c++) weights[c] = 1;
    if (nCh == 6) { double w[6] = {1, 1, 1, 0, 1.41, 1.41}; memcpy(weights, w, sizeof w); }
    if (nCh == 5) { double w[5] = {1, 1, 1, 1.41, 1.41}; memcpy(weights, w, sizeof w); }
    if (nCh > 8) nCh = 8;

    double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
    double K = tan(M_PI * f0 / fs);
    double Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416);
    double a0 = 1 + K / Q + K * K;
    double sb0 = (Vh + Vb * K / Q + K * K) / a0, sb1 = 2 * (K * K - Vh) / a0, sb2 = (Vh - Vb * K / Q + K * K) / a0;
    double sa1 = 2 * (K * K - 1) / a0, sa2 = (1 - K / Q + K * K) / a0;
    f0 = 38.13547087602444; Q = 0.5003270373238773;
    K = tan(M_PI * f0 / fs);
    a0 = 1 + K / Q + K * K;
    double ha1 = 2 * (K * K - 1) / a0, ha2 = (1 - K / Q + K * K) / a0;

    long step = lround(fs * 0.1);
    long segs = n / step;
    if (segs < 4) return -INFINITY;
    double *segPower = calloc(segs, sizeof(double));
    for (int c = 0; c < nCh; c++) {
        if (weights[c] <= 0) continue;
        double z1a = 0, z2a = 0, z1b = 0, z2b = 0, w = weights[c];
        const float *x = chs[c];
        for (long s = 0; s < segs; s++) {
            double acc = 0;
            for (long i = s * step, e = s * step + step; i < e; i++) {
                double xin = x[i];
                double y1 = sb0 * xin + z1a;
                z1a = sb1 * xin - sa1 * y1 + z2a;
                z2a = sb2 * xin - sa2 * y1;
                double y2 = y1 + z1b;
                z1b = -2 * y1 - ha1 * y2 + z2b;
                z2b = y1 - ha2 * y2;
                acc += y2 * y2;
            }
            segPower[s] += w * acc;
        }
    }
    long nb = segs - 3;
    double blockLen = (double)(step * 4);
    double *blocks = malloc(sizeof(double) * nb);
    for (long b = 0; b < nb; b++)
        blocks[b] = (segPower[b] + segPower[b + 1] + segPower[b + 2] + segPower[b + 3]) / blockLen;
#define LK(z) (-0.691 + 10 * log10(z))
    double sum = 0; long cnt = 0;
    for (long b = 0; b < nb; b++) if (blocks[b] > 0 && LK(blocks[b]) > -70) { sum += blocks[b]; cnt++; }
    double r = -INFINITY;
    if (cnt > 0) {
        double rel = LK(sum / cnt) - 10;
        double s2 = 0; long c2 = 0;
        for (long b = 0; b < nb; b++)
            if (blocks[b] > 0 && LK(blocks[b]) > -70 && LK(blocks[b]) > rel) { s2 += blocks[b]; c2++; }
        if (c2 > 0) r = LK(s2 / c2);
    }
    free(segPower); free(blocks);
    return r;
}

float lp_sample_peak(const float *const *chs, int nCh, long n) {
    float peak = 0;
    for (int c = 0; c < nCh; c++) {
        const float *x = chs[c];
        float m = 0;
        for (long i = 0; i < n; i++) { float v = fabsf(x[i]); if (v > m) m = v; }
        if (m > peak) peak = m;
    }
    return peak;
}

static double bessel_i0(double x) {
    double sum = 1, term = 1, k = 1;
    while (term > 1e-12 * sum) { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1; }
    return sum;
}

float lp_true_peak(const float *const *chs, int nCh, long n, double fs) {
    float peak = lp_sample_peak(chs, nCh, n);
    int L = fs < 96000 ? 4 : (fs < 192000 ? 2 : 1);
    if (L == 1 || n <= 0) return peak;
    enum { T = 48 };
    int total = T * L;
    double beta = 8.0, center = total / 2.0, denom = bessel_i0(beta);
    float ph[4][T];
    for (int k = 0; k < total; k++) {
        double t = (k - center) / L;
        double sinc = t == 0 ? 1.0 : sin(M_PI * t) / (M_PI * t);
        double r = (k - center) / center;
        double win = fabs(r) <= 1 ? bessel_i0(beta * sqrt(1 - r * r)) / denom : 0;
        ph[k % L][k / L] = (float)(sinc * win);
    }
    for (int p = 0; p < L; p++) {
        float s = 0;
        for (int k = 0; k < T; k++) s += ph[p][k];
        if (s != 0) for (int k = 0; k < T; k++) ph[p][k] /= s;
    }
    /* vDSP_conv(padded, 1, f + T-1, -1, out, ...): out[i] = sum_k padded[i+k] * f[T-1-k].
       Pre-reverse the filters so the inner loop is a plain dot product. */
    float rev[4][T];
    for (int p = 0; p < L; p++) for (int k = 0; k < T; k++) rev[p][k] = ph[p][T - 1 - k];
    long outCount = n + T - 1;
    float *padded = calloc(n + 2 * (T - 1), sizeof(float));
    for (int c = 0; c < nCh; c++) {
        memcpy(padded + (T - 1), chs[c], sizeof(float) * n);
        for (int p = 0; p < L; p++) {
            const float *f = rev[p];
            float mx = 0, mn = 0;
            for (long i = 0; i < outCount; i++) {
                float acc = dot(padded + i, f, T);
                if (acc > mx) mx = acc;
                if (acc < mn) mn = acc;
            }
            if (mx > peak) peak = mx;
            if (-mn > peak) peak = -mn;
        }
    }
    free(padded);
    return peak;
}

float *lp_limiter_envelope(const float *const *chs, int nCh, long n, double gain_db, double fs) {
    float gain = (float)pow(10, gain_db / 20), thr = (float)pow(10, -1.0 / 20);
    long La = lround(0.005 * fs); if (La < 1) La = 1;
    float rel = (float)exp(-1 / (0.100 * fs));
    long m = n + La;
    float *req = malloc(sizeof(float) * m);
    for (long i = 0; i < m; i++) req[i] = 1;
    int engaged = 0;
    for (long i = 0; i < n; i++) {
        float p = 0;
        for (int c = 0; c < nCh; c++) { float v = fabsf(chs[c][i]); if (v > p) p = v; }
        p *= gain;
        if (p > thr) { req[i + La] = thr / p; engaged = 1; }
    }
    if (!engaged) { free(req); return NULL; }
    float *hold = malloc(sizeof(float) * m);
    long *dq = malloc(sizeof(long) * (m + 1));
    long head = 0, tail = 0, j = 0;
    for (long i = 0; i < m; i++) {
        while (j < m && j <= i + La) {
            while (tail > head && req[dq[tail - 1]] >= req[j]) tail--;
            dq[tail++] = j++;
        }
        while (dq[head] < i) head++;
        hold[i] = req[dq[head]];
    }
    free(dq); free(req);
    float g = 1;
    for (long i = 0; i < m; i++) {
        float h = hold[i];
        g = h < g ? h : rel * g + (1 - rel) * h;
        hold[i] = g;
    }
    float *env = malloc(sizeof(float) * (n + 1));
    for (long i = 0; i < n; i++) env[i] = 1;
    float *win = malloc(sizeof(float) * (La + 1));
    for (long i = 0; i <= La; i++) win[i] = 1;
    double sum = (double)(La + 1);
    for (long i = 0; i < m; i++) {
        long k = i % (La + 1);
        sum += (double)hold[i] - (double)win[k];
        win[k] = hold[i];
        if (i >= La) env[i - La] = (float)(sum / (double)(La + 1));
    }
    free(win); free(hold);
    return env;
}

void lp_waveform(const float *const *chs, int nCh, long n, int buckets, float *out) {
    for (int b = 0; b < buckets; b++) out[b] = 0;
    if (n <= 0) return;
    for (int b = 0; b < buckets; b++) {
        long s = (long)((long long)b * n / buckets);
        long e = (long)(((long long)b + 1) * n / buckets);
        if (e < s + 1) e = s + 1;
        if (s >= n) break;
        if (e > n) e = n;
        float m = 0;
        for (int c = 0; c < nCh; c++)
            for (long i = s; i < e; i++) { float v = fabsf(chs[c][i]); if (v > m) m = v; }
        out[b] = m;
    }
}

/* Lag of x relative to ref (same algorithm as Processing.align): positive = x is late. */
long lp_align_lag(const float *const *x, int xch, long xn, const float *const *ref, int rch, long rn) {
    const long L = 8192, W = 32768;
    long n = rn;
    if (!(n > W + 2 * L && xn > W + 2 * L)) return 0;
    long span = (n < xn ? n : xn) - W - 2 * L;
    float *r = malloc(sizeof(float) * n), *d = malloc(sizeof(float) * xn);
    memcpy(r, ref[0], sizeof(float) * n);
    for (int c = 1; c < rch; c++) for (long i = 0; i < n; i++) r[i] += ref[c][i];
    memcpy(d, x[0], sizeof(float) * xn);
    for (int c = 1; c < xch; c++) for (long i = 0; i < xn; i++) d[i] += x[c][i];
    long best = L; float bestE = -1;
    for (int k = 0; k < 24; k++) {
        long s = L + span * k / 23;
        float e = 0;
        for (long i = s; i < s + W; i++) e += r[i] * r[i];
        if (e > bestE) { bestE = e; best = s; }
    }
    const float *seg = d + (best - L), *tpl = r + best;
    long bi = 0; float mx = -INFINITY;
    for (long i = 0; i < 2 * L + 1; i++) {
        float acc = dot(seg + i, tpl, W);
        if (acc > mx) { mx = acc; bi = i; }
    }
    free(r); free(d);
    return bi - L;
}
