/* speexdsp resampler with a wasm SIMD inner product (speex's own SIMD paths are SSE/NEON only). */
#ifdef __wasm_simd128__
#include <wasm_simd128.h>
#define OVERRIDE_INNER_PRODUCT_SINGLE
static inline float inner_product_single(const float *a, const float *b, unsigned int len) {
    v128_t s0 = wasm_f32x4_splat(0), s1 = s0;
    unsigned int i = 0;
    for (; i + 8 <= len; i += 8) {
        s0 = wasm_f32x4_add(s0, wasm_f32x4_mul(wasm_v128_load(a + i), wasm_v128_load(b + i)));
        s1 = wasm_f32x4_add(s1, wasm_f32x4_mul(wasm_v128_load(a + i + 4), wasm_v128_load(b + i + 4)));
    }
    s0 = wasm_f32x4_add(s0, s1);
    float r = wasm_f32x4_extract_lane(s0, 0) + wasm_f32x4_extract_lane(s0, 1)
            + wasm_f32x4_extract_lane(s0, 2) + wasm_f32x4_extract_lane(s0, 3);
    for (; i < len; i++) r += a[i] * b[i];
    return r;
}

/* Used for rates whose ratio needs the interpolated (oversampled) sinc table, e.g. 48k <-> 44.1k. */
#define OVERRIDE_INTERPOLATE_PRODUCT_SINGLE
static inline float interpolate_product_single(const float *a, const float *b, unsigned int len,
                                               const unsigned int oversample, float *frac) {
    v128_t s0 = wasm_f32x4_splat(0), s1 = s0;
    unsigned int i = 0;
    for (; i + 2 <= len; i += 2) {
        s0 = wasm_f32x4_add(s0, wasm_f32x4_mul(wasm_f32x4_splat(a[i]), wasm_v128_load(b + i * oversample)));
        s1 = wasm_f32x4_add(s1, wasm_f32x4_mul(wasm_f32x4_splat(a[i + 1]), wasm_v128_load(b + (i + 1) * oversample)));
    }
    for (; i < len; i++)
        s0 = wasm_f32x4_add(s0, wasm_f32x4_mul(wasm_f32x4_splat(a[i]), wasm_v128_load(b + i * oversample)));
    s0 = wasm_f32x4_mul(wasm_f32x4_add(s0, s1), wasm_v128_load(frac));
    return wasm_f32x4_extract_lane(s0, 0) + wasm_f32x4_extract_lane(s0, 1)
         + wasm_f32x4_extract_lane(s0, 2) + wasm_f32x4_extract_lane(s0, 3);
}

/* Quality > 8 (we use 10) takes the double-accumulator paths; same math as speex's SSE2 versions. */
#define LO(t) wasm_f64x2_promote_low_f32x4(t)
#define HI(t) wasm_f64x2_promote_low_f32x4(wasm_i32x4_shuffle(t, t, 2, 3, 0, 1))
#define OVERRIDE_INNER_PRODUCT_DOUBLE
static inline double inner_product_double(const float *a, const float *b, unsigned int len) {
    v128_t s = wasm_f64x2_splat(0);
    unsigned int i = 0;
    for (; i + 4 <= len; i += 4) {
        v128_t t = wasm_f32x4_mul(wasm_v128_load(a + i), wasm_v128_load(b + i));
        s = wasm_f64x2_add(s, wasm_f64x2_add(LO(t), HI(t)));
    }
    double r = wasm_f64x2_extract_lane(s, 0) + wasm_f64x2_extract_lane(s, 1);
    for (; i < len; i++) r += (double)(a[i] * b[i]);
    return r;
}
#define OVERRIDE_INTERPOLATE_PRODUCT_DOUBLE
static inline double interpolate_product_double(const float *a, const float *b, unsigned int len,
                                                const unsigned int oversample, float *frac) {
    v128_t s1 = wasm_f64x2_splat(0), s2 = s1;
    for (unsigned int i = 0; i < len; i++) {
        v128_t t = wasm_f32x4_mul(wasm_f32x4_splat(a[i]), wasm_v128_load(b + i * oversample));
        s1 = wasm_f64x2_add(s1, LO(t));
        s2 = wasm_f64x2_add(s2, HI(t));
    }
    v128_t f = wasm_v128_load(frac);
    v128_t s = wasm_f64x2_add(wasm_f64x2_mul(LO(f), s1), wasm_f64x2_mul(HI(f), s2));
    return wasm_f64x2_extract_lane(s, 0) + wasm_f64x2_extract_lane(s, 1);
}
#endif
/* Exact per-phase sinc table (faster + more accurate than the interpolated table for 44.1k <-> 48k). */
#define RESAMPLE_FULL_SINC_TABLE
#include "resample.c"
