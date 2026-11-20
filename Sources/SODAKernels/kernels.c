#include "SODAKernels.h"

#include <arm_neon.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

static int32_t tail(const int8_t *x, const int8_t *w, int k, int n) {
    int32_t s = 0;
    for (; k < n; k++) s += (int32_t)x[k] * w[k];
    return s;
}

void soda_dot_s8(const int8_t *x, int batch, const int8_t *w, int units, int n, int32_t *out) {
    const int n16 = n & ~15;
    int b = 0;
    // Four inputs and four weight rows at a time: each load feeds four products.
    for (; b + 4 <= batch; b += 4) {
        const int8_t *x0 = x + (long)b * n;
        int u = 0;
        for (; u + 4 <= units; u += 4) {
            const int8_t *w0 = w + (long)u * n, *w1 = w0 + n, *w2 = w1 + n, *w3 = w2 + n;
            int32x4_t a[4][4];
            for (int j = 0; j < 4; j++)
                for (int i = 0; i < 4; i++) a[j][i] = vdupq_n_s32(0);
            for (int k = 0; k < n16; k += 16) {
                int8x16_t v0 = vld1q_s8(w0 + k), v1 = vld1q_s8(w1 + k), v2 = vld1q_s8(w2 + k), v3 = vld1q_s8(w3 + k);
                for (int j = 0; j < 4; j++) {
                    int8x16_t xv = vld1q_s8(x0 + (long)j * n + k);
                    a[j][0] = vdotq_s32(a[j][0], xv, v0);
                    a[j][1] = vdotq_s32(a[j][1], xv, v1);
                    a[j][2] = vdotq_s32(a[j][2], xv, v2);
                    a[j][3] = vdotq_s32(a[j][3], xv, v3);
                }
            }
            for (int j = 0; j < 4; j++) {
                const int8_t *xj = x0 + (long)j * n;
                out[(long)(b + j) * units + u] = vaddvq_s32(a[j][0]) + tail(xj, w0, n16, n);
                out[(long)(b + j) * units + u + 1] = vaddvq_s32(a[j][1]) + tail(xj, w1, n16, n);
                out[(long)(b + j) * units + u + 2] = vaddvq_s32(a[j][2]) + tail(xj, w2, n16, n);
                out[(long)(b + j) * units + u + 3] = vaddvq_s32(a[j][3]) + tail(xj, w3, n16, n);
            }
        }
        for (; u < units; u++) {
            const int8_t *wr = w + (long)u * n;
            for (int j = 0; j < 4; j++) {
                const int8_t *xj = x0 + (long)j * n;
                int32x4_t a0 = vdupq_n_s32(0);
                for (int k = 0; k < n16; k += 16) a0 = vdotq_s32(a0, vld1q_s8(xj + k), vld1q_s8(wr + k));
                out[(long)(b + j) * units + u] = vaddvq_s32(a0) + tail(xj, wr, n16, n);
            }
        }
    }
    // Two inputs and four weight rows at a time.
    for (; b + 2 <= batch; b += 2) {
        const int8_t *x0 = x + (long)b * n, *x1 = x0 + n;
        int u = 0;
        for (; u + 4 <= units; u += 4) {
            const int8_t *w0 = w + (long)u * n, *w1 = w0 + n, *w2 = w1 + n, *w3 = w2 + n;
            int32x4_t a[2][4];
            for (int j = 0; j < 2; j++)
                for (int i = 0; i < 4; i++) a[j][i] = vdupq_n_s32(0);
            for (int k = 0; k < n16; k += 16) {
                int8x16_t v0 = vld1q_s8(w0 + k), v1 = vld1q_s8(w1 + k), v2 = vld1q_s8(w2 + k), v3 = vld1q_s8(w3 + k);
                int8x16_t xa = vld1q_s8(x0 + k), xb = vld1q_s8(x1 + k);
                a[0][0] = vdotq_s32(a[0][0], xa, v0);
                a[0][1] = vdotq_s32(a[0][1], xa, v1);
                a[0][2] = vdotq_s32(a[0][2], xa, v2);
                a[0][3] = vdotq_s32(a[0][3], xa, v3);
                a[1][0] = vdotq_s32(a[1][0], xb, v0);
                a[1][1] = vdotq_s32(a[1][1], xb, v1);
                a[1][2] = vdotq_s32(a[1][2], xb, v2);
                a[1][3] = vdotq_s32(a[1][3], xb, v3);
            }
            const int8_t *ws[4] = {w0, w1, w2, w3};
            for (int j = 0; j < 2; j++) {
                const int8_t *xj = j ? x1 : x0;
                for (int i = 0; i < 4; i++)
                    out[(long)(b + j) * units + u + i] = vaddvq_s32(a[j][i]) + tail(xj, ws[i], n16, n);
            }
        }
        for (; u < units; u++) {
            const int8_t *wr = w + (long)u * n;
            int32x4_t a0 = vdupq_n_s32(0), a1 = vdupq_n_s32(0);
            for (int k = 0; k < n16; k += 16) {
                int8x16_t wv = vld1q_s8(wr + k);
                a0 = vdotq_s32(a0, vld1q_s8(x0 + k), wv);
                a1 = vdotq_s32(a1, vld1q_s8(x1 + k), wv);
            }
            out[(long)b * units + u] = vaddvq_s32(a0) + tail(x0, wr, n16, n);
            out[(long)(b + 1) * units + u] = vaddvq_s32(a1) + tail(x1, wr, n16, n);
        }
    }
    // The other input, four weight rows at a time.
    for (; b < batch; b++) {
        const int8_t *xb = x + (long)b * n;
        int u = 0;
        for (; u + 4 <= units; u += 4) {
            const int8_t *w0 = w + (long)u * n, *w1 = w0 + n, *w2 = w1 + n, *w3 = w2 + n;
            int32x4_t a0 = vdupq_n_s32(0), a1 = vdupq_n_s32(0), a2 = vdupq_n_s32(0), a3 = vdupq_n_s32(0);
            for (int k = 0; k < n16; k += 16) {
                int8x16_t xv = vld1q_s8(xb + k);
                a0 = vdotq_s32(a0, xv, vld1q_s8(w0 + k));
                a1 = vdotq_s32(a1, xv, vld1q_s8(w1 + k));
                a2 = vdotq_s32(a2, xv, vld1q_s8(w2 + k));
                a3 = vdotq_s32(a3, xv, vld1q_s8(w3 + k));
            }
            out[(long)b * units + u] = vaddvq_s32(a0) + tail(xb, w0, n16, n);
            out[(long)b * units + u + 1] = vaddvq_s32(a1) + tail(xb, w1, n16, n);
            out[(long)b * units + u + 2] = vaddvq_s32(a2) + tail(xb, w2, n16, n);
            out[(long)b * units + u + 3] = vaddvq_s32(a3) + tail(xb, w3, n16, n);
        }
        for (; u < units; u++) {
            const int8_t *wr = w + (long)u * n;
            int32x4_t a0 = vdupq_n_s32(0);
            for (int k = 0; k < n16; k += 16) a0 = vdotq_s32(a0, vld1q_s8(xb + k), vld1q_s8(wr + k));
            out[(long)b * units + u] = vaddvq_s32(a0) + tail(xb, wr, n16, n);
        }
    }
}

// The 4-bit weights' value k of a row.
static inline int32_t nibble(const uint8_t *row, int k) {
    const uint8_t b = row[k / 2];
    return k % 2 == 0 ? (int8_t)(uint8_t)(b << 4) >> 4 : (int8_t)b >> 4;
}

// `nb` inputs and four weight rows at a time: 16 bytes of a row are 32 values, the low nibbles (sign-extended) the
// even ones and the high nibbles the odd ones, multiplied with the inputs' even and odd values (vld2q_s8).
static inline __attribute__((always_inline)) void dot_s4_rows(const int8_t *x, int nb, const uint8_t *w, int units,
                                                              int n, int32_t *out) {
    const int n32 = n & ~31;
    const long bytes = n / 2;
    int u = 0;
    for (; u + 4 <= units; u += 4) {
        int32x4_t a[4][4];
        for (int t = 0; t < nb; t++)
            for (int i = 0; i < 4; i++) a[t][i] = vdupq_n_s32(0);
        for (int k = 0; k < n32; k += 32) {
            int8x16_t lo[4], hi[4];
            for (int i = 0; i < 4; i++) {
                const int8x16_t p = vld1q_s8((const int8_t *)w + (u + i) * bytes + k / 2);
                lo[i] = vshrq_n_s8(vshlq_n_s8(p, 4), 4);
                hi[i] = vshrq_n_s8(p, 4);
            }
            for (int t = 0; t < nb; t++) {
                const int8x16x2_t xv = vld2q_s8(x + (long)t * n + k);
                for (int i = 0; i < 4; i++) a[t][i] = vdotq_s32(vdotq_s32(a[t][i], xv.val[0], lo[i]), xv.val[1], hi[i]);
            }
        }
        for (int t = 0; t < nb; t++)
            for (int i = 0; i < 4; i++) {
                int32_t s = vaddvq_s32(a[t][i]);
                for (int k = n32; k < n; k++) s += (int32_t)x[(long)t * n + k] * nibble(w + (u + i) * bytes, k);
                out[(long)t * units + u + i] = s;
            }
    }
    for (; u < units; u++)
        for (int t = 0; t < nb; t++) {
            int32_t s = 0;
            for (int k = 0; k < n; k++) s += (int32_t)x[(long)t * n + k] * nibble(w + u * bytes, k);
            out[(long)t * units + u] = s;
        }
}

void soda_dot_s4(const int8_t *x, int batch, const uint8_t *w, int units, int n, int32_t *out) {
    int b = 0;
    for (; b + 4 <= batch; b += 4) dot_s4_rows(x + (long)b * n, 4, w, units, n, out + (long)b * units);
    for (; b < batch; b++) dot_s4_rows(x + (long)b * n, 1, w, units, n, out + (long)b * units);
}

void soda_row_sums_s8(const int8_t *w, long rows, int n, int32_t *out) {
    for (long r = 0; r < rows; r++) {
        const int8_t *wr = w + r * n;
        int32_t s = 0;
        for (int k = 0; k < n; k++) s += wr[k];
        out[r] = s;
    }
}

void soda_depthwise_s8(const int8_t *q, int zero, int height, int width, int channels, const int8_t *w, int fh, int fw,
                       int stride_h, int stride_w, int dilation_h, int dilation_w, int pad_h, int pad_w, int out_h,
                       int out_w, int32_t *acc) {
    for (int oy = 0; oy < out_h; oy++) {
        for (int ox = 0; ox < out_w; ox++) {
            int32_t *a = acc + ((long)oy * out_w + ox) * channels;
            for (int c = 0; c < channels; c++) a[c] = 0;
            for (int ky = 0; ky < fh; ky++) {
                int iy = oy * stride_h - pad_h + ky * dilation_h;
                if (iy < 0 || iy >= height) continue;
                for (int kx = 0; kx < fw; kx++) {
                    int ix = ox * stride_w - pad_w + kx * dilation_w;
                    if (ix < 0 || ix >= width) continue;
                    const int8_t *x = q + ((long)iy * width + ix) * channels;
                    const int8_t *f = w + ((long)ky * fw + kx) * channels;
                    for (int c = 0; c < channels; c++) a[c] += (int32_t)f[c] * ((int32_t)x[c] - zero);
                }
            }
        }
    }
}

// Block j's column index, of `size` bytes.
static inline __attribute__((always_inline)) long column(const void *indices, int size, int j) {
    return size == 1 ? ((const uint8_t *)indices)[j] : size == 2 ? ((const uint16_t *)indices)[j]
                                                                 : ((const uint32_t *)indices)[j];
}

// Four input rows at once (their sums `units` apart in `out`): each weight block is loaded once, and every row sums
// into two accumulators (even and odd blocks), so that the dot products don't wait on each other.
static inline __attribute__((always_inline)) void sparse_rows4(const int8_t *x, const int8_t *values,
                                                               const int32_t *segments, const void *indices, int size,
                                                               int units, int n, int32_t *out) {
    for (int u = 0; u < units; u++) {
        int32x4_t a[4][2];
        for (int t = 0; t < 4; t++) a[t][0] = a[t][1] = vdupq_n_s32(0);
        int j = segments[u];
        const int end = segments[u + 1];
        for (; j + 2 <= end; j += 2) {
            const int8x16_t w0 = vld1q_s8(values + 16L * j), w1 = vld1q_s8(values + 16L * (j + 1));
            const long c0 = 16L * column(indices, size, j), c1 = 16L * column(indices, size, j + 1);
            for (int t = 0; t < 4; t++) {
                a[t][0] = vdotq_s32(a[t][0], vld1q_s8(x + (long)t * n + c0), w0);
                a[t][1] = vdotq_s32(a[t][1], vld1q_s8(x + (long)t * n + c1), w1);
            }
        }
        if (j < end) {
            const int8x16_t w0 = vld1q_s8(values + 16L * j);
            const long c0 = 16L * column(indices, size, j);
            for (int t = 0; t < 4; t++) a[t][0] = vdotq_s32(a[t][0], vld1q_s8(x + (long)t * n + c0), w0);
        }
        for (int t = 0; t < 4; t++) out[(long)t * units + u] = vaddvq_s32(vaddq_s32(a[t][0], a[t][1]));
    }
}

// One or two input rows: the per-unit loop above mispredicts its end at every unit (a unit has a few blocks), which
// costs more than the dot products with fewer rows to share it. Instead one loop runs over all the blocks, two at a
// time, the rows summing the even and the odd blocks apart; after each pair the running sums go to `pre`, as scalars
// (two rows: [even, odd, even', odd']; one row: [even, even, odd, odd], halves of each). A unit's sums are the
// differences of the running sums at its ends, wrapping as the sums do, so exact.
static inline __attribute__((always_inline)) void sparse_rows_prefix(const int8_t *x, int nb, const int8_t *values,
                                                                     const int32_t *segments, const void *indices,
                                                                     int size, int units, int n, int32_t *out,
                                                                     int32_t *pre) {
    const int total = segments[units];
    int32x4_t e[2], o[2];
    for (int t = 0; t < nb; t++) e[t] = o[t] = vdupq_n_s32(0);
    vst1q_s32(pre, vdupq_n_s32(0));
    int32_t *at = pre + 4;
    int j = 0;
    for (; j + 2 <= total; j += 2, at += 4) {
        const int8x16_t w0 = vld1q_s8(values + 16L * j), w1 = vld1q_s8(values + 16L * (j + 1));
        const long c0 = 16L * column(indices, size, j), c1 = 16L * column(indices, size, j + 1);
        for (int t = 0; t < nb; t++) {
            e[t] = vdotq_s32(e[t], vld1q_s8(x + (long)t * n + c0), w0);
            o[t] = vdotq_s32(o[t], vld1q_s8(x + (long)t * n + c1), w1);
        }
        vst1q_s32(at, nb == 1 ? vpaddq_s32(e[0], o[0]) : vpaddq_s32(vpaddq_s32(e[0], o[0]), vpaddq_s32(e[1], o[1])));
    }
    if (j < total) {
        const int8x16_t w0 = vld1q_s8(values + 16L * j);
        const long c0 = 16L * column(indices, size, j);
        for (int t = 0; t < nb; t++) e[t] = vdotq_s32(e[t], vld1q_s8(x + (long)t * n + c0), w0);
        vst1q_s32(at, nb == 1 ? vpaddq_s32(e[0], o[0]) : vpaddq_s32(vpaddq_s32(e[0], o[0]), vpaddq_s32(e[1], o[1])));
    }
    // The sum of the blocks before block b: the even blocks' after pair ⌈b/2⌉, the odd ones' after pair ⌊b/2⌋.
    const uint32_t *p = (const uint32_t *)pre;
    for (int t = 0; t < nb; t++) {
        uint32_t last = 0;
        for (int u = 0; u < units; u++) {
            const int b = segments[u + 1];
            const uint32_t *even = p + 4L * ((b + 1) >> 1), *odd = p + 4L * (b >> 1);
            const uint32_t next = nb == 1 ? even[0] + even[1] + odd[2] + odd[3] : even[2 * t] + odd[2 * t + 1];
            out[(long)t * units + u] = (int32_t)(next - last);
            last = next;
        }
    }
}

static inline __attribute__((always_inline)) void sparse_dot(const int8_t *x, int batch, const int8_t *values,
                                                             const int32_t *segments, const void *indices, int size,
                                                             int units, int n, int32_t *out, int32_t *scratch) {
    int b = 0;
    for (; b + 4 <= batch; b += 4)
        sparse_rows4(x + (long)b * n, values, segments, indices, size, units, n, out + (long)b * units);
    for (; b + 2 <= batch; b += 2)
        sparse_rows_prefix(x + (long)b * n, 2, values, segments, indices, size, units, n, out + (long)b * units, scratch);
    if (b < batch)
        sparse_rows_prefix(x + (long)b * n, 1, values, segments, indices, size, units, n, out + (long)b * units, scratch);
}

// A copy of the kernels per index size.
void soda_sparse_dot_s8(const int8_t *x, int batch, const int8_t *values, const int32_t *segments,
                        const void *indices, int index_size, int units, int n, int32_t *out, int32_t *scratch) {
    switch (index_size) {
    case 1: sparse_dot(x, batch, values, segments, indices, 1, units, n, out, scratch); break;
    case 2: sparse_dot(x, batch, values, segments, indices, 2, units, n, out, scratch); break;
    default: sparse_dot(x, batch, values, segments, indices, 4, units, n, out, scratch); break;
    }
}

int soda_all_zero(const float *x, long n) {
    for (long i = 0; i < n; i++)
        if (x[i] != 0) return 0;
    return 1;
}

static void range(const float *x, int n, float *low, float *high) {
    float lo = x[0], hi = x[0];
    int i = 0;
    if (n >= 4) {
        float32x4_t vlo = vld1q_f32(x), vhi = vlo;
        for (i = 4; i + 4 <= n; i += 4) {
            float32x4_t v = vld1q_f32(x + i);
            vlo = vminq_f32(vlo, v);
            vhi = vmaxq_f32(vhi, v);
        }
        lo = vminvq_f32(vlo);
        hi = vmaxvq_f32(vhi);
    }
    for (; i < n; i++) {
        lo = x[i] < lo ? x[i] : lo;
        hi = x[i] > hi ? x[i] : hi;
    }
    *low = lo;
    *high = hi;
}

// q[i] = clamp(zero + round(x[i] · inverse), min, 127), rounding half away from zero.
static void scale_row(const float *x, int n, int8_t *q, float inverse, int32_t zero, int32_t min) {
    const float32x4_t vinv = vdupq_n_f32(inverse);
    const int32x4_t vzero = vdupq_n_s32(zero), vmin = vdupq_n_s32(min), vmax = vdupq_n_s32(127);
    int i = 0;
    for (; i + 8 <= n; i += 8) {
        int32x4_t a = vaddq_s32(vcvtaq_s32_f32(vmulq_f32(vld1q_f32(x + i), vinv)), vzero);
        int32x4_t b = vaddq_s32(vcvtaq_s32_f32(vmulq_f32(vld1q_f32(x + i + 4), vinv)), vzero);
        a = vminq_s32(vmaxq_s32(a, vmin), vmax);
        b = vminq_s32(vmaxq_s32(b, vmin), vmax);
        int16x8_t h = vcombine_s16(vmovn_s32(a), vmovn_s32(b));
        vst1_s8(q + i, vmovn_s16(h));
    }
    for (; i < n; i++) {
        int32_t v = zero + (int32_t)roundf(x[i] * inverse);
        q[i] = (int8_t)(v < min ? min : v > 127 ? 127 : v);
    }
}

float soda_quantize_symmetric(const float *x, int n, int8_t *q) {
    if (n <= 0) return 1;
    float low, high;
    range(x, n, &low, &high);
    const float r = fabsf(low) > fabsf(high) ? fabsf(low) : fabsf(high);
    if (r == 0) {
        memset(q, 0, (size_t)n);
        return 1;
    }
    scale_row(x, n, q, 127 / r, 0, -127);
    return r / 127;
}

void soda_quantize_asymmetric(const float *x, int n, int8_t *q, float *scale, int32_t *zero) {
    float low = 0, high = 0;
    if (n > 0) range(x, n, &low, &high);
    if (low == high) {
        memset(q, 0, (size_t)n);
        *scale = 1;
        *zero = 0;
        return;
    }
    const double rmin = low, rmax = high;
    const double s = (double)(high - low) / 255;
    const double from_min = -128 - rmin / s, from_max = 127 - rmax / s;
    const double z = 128 + fabs(rmin / s) < 127 + fabs(rmax / s) ? from_min : from_max;
    const int32_t zp = z <= -128 ? -128 : z >= 127 ? 127 : (int32_t)round(z);
    const float factor = (float)s;
    scale_row(x, n, q, (float)(1.0 / (double)factor), zp, -128);
    *scale = factor;
    *zero = zp;
}

static inline float min_f(float x, float y) { return y < x ? y : x; }  // Swift's min(x, y)
static inline float max_f(float x, float y) { return y >= x ? y : x; } // Swift's max(x, y)

void soda_logistic(const float *restrict x, float *restrict out, long n) {
    for (long i = 0; i < n; i++) {
        const float input = x[i];
        float v = min_f(input, 16.6355324f) * 0.5f;
        const float m = floorf(fmaf(v, 1.44269504088896341f, 0.5f));
        float r = fmaf(m, -0.693359375f, v);
        r = fmaf(m, 2.12194440e-4f, r);
        const float r2 = r * r;
        const float even = fmaf(r2, 4.1898667812347412109375e-2f, 0.49999141693115234375f);
        const float odd = fmaf(r2, 8.33471305668354034423828125e-3f, 0.16666877269744873046875f);
        const float low = r + 1;
        float p = fmaf(r, odd, even);
        p = fmaf(r2, p, low);
        const float b = min_f(max_f(m + 127, 0), 255);
        union { uint32_t u; float f; } scale = {.u = (uint32_t)(int32_t)b << 23};
        float e = p * scale.f;
        e = e * e;
        out[i] = input < -104 ? 0 : e / (1 + e);
    }
}

void soda_tanh(const float *restrict x, float *restrict out, long n) {
    for (long i = 0; i < n; i++) {
        const float v = min_f(max_f(x[i], -8.01773357391357422f), 8.01773357391357422f);
        const float x2 = v * v, x3 = x2 * v;
        float p = 1.394553628e-8f;
        p = fmaf(p, x2, 2.102733560e-5f);
        p = fmaf(p, x2, 3.520756727e-3f);
        p = fmaf(p, x2, 1.340216100e-1f);
        float q = 8.015776984e-7f;
        q = fmaf(q, x2, 3.326951409e-4f);
        q = fmaf(q, x2, 2.597254514e-2f);
        q = fmaf(q, x2, 4.673548340e-1f);
        q = fmaf(q, x2, 1.0f);
        p = fmaf(x3, p, v);
        out[i] = p / q;
    }
}

// Eigen's pldexp_generic: a · 2^exponent in four factors.
static inline float ldexp_eigen(float a, float exponent) {
    const int32_t e = (int32_t)min_f(max_f(exponent, -278), 278);
    int32_t b = e >> 2;
    union { uint32_t u; float f; } c = {.u = (uint32_t)(b + 127) << 23};
    float out = a * c.f * c.f * c.f;
    b = e - 3 * b;
    c.u = (uint32_t)(b + 127) << 23;
    return out * c.f;
}

void soda_packet_exp(const float *restrict x, float *restrict out, long n) {
    for (long i = 0; i < n; i++) {
        const float input = x[i];
        const float v = min_f(input, 88.723f);
        const float m = floorf(fmaf(v, 1.44269504088896341f, 0.5f));
        float r = fmaf(m, -0.693359375f, v);
        r = fmaf(m, 2.12194440e-4f, r);
        const float r2 = r * r;
        float even = fmaf(r2, 1.37449637986719608306884765625e-3f, 4.166965186595916748046875e-2f);
        const float odd = fmaf(r2, 8.36894474923610687255859375e-3f, 0.16666518151760101318359375f);
        even = fmaf(r2, even, 0.49999988079071044921875f);
        const float low = r + 1;
        float y = fmaf(r, odd, even);
        y = fmaf(r2, y, low);
        out[i] = input < -104 ? 0 : max_f(ldexp_eigen(y, m), input);
    }
}

#define BINARY_LOOP(EXPR)                                                                     \
    for (long i = 0; i < outer; i++) {                                                        \
        const float *a = x + i * x_outer, *b = y + i * y_outer;                               \
        float *o = out + i * inner;                                                           \
        if (x_inner && y_inner) {                                                             \
            for (long j = 0; j < inner; j++) { const float p = a[j], q = b[j]; o[j] = EXPR; } \
        } else if (x_inner) {                                                                 \
            const float q = b[0];                                                             \
            for (long j = 0; j < inner; j++) { const float p = a[j]; o[j] = EXPR; }           \
        } else if (y_inner) {                                                                 \
            const float p = a[0];                                                             \
            for (long j = 0; j < inner; j++) { const float q = b[j]; o[j] = EXPR; }           \
        } else {                                                                              \
            const float p = a[0], q = b[0];                                                   \
            for (long j = 0; j < inner; j++) o[j] = EXPR;                                     \
        }                                                                                     \
    }

static inline float floor_mod(float p, float q) {
    const float t = fmodf(p, q);
    return t != 0 && (q < 0) != (t < 0) ? t + q : t;
}

int soda_binary(int op, const float *x, long x_outer, int x_inner, const float *y, long y_outer, int y_inner,
                float *out, long outer, long inner) {
    switch (op) {
    case 0: BINARY_LOOP(p + q) break;
    case 18: BINARY_LOOP(p * q) break;
    case 41: BINARY_LOOP(p - q) break;
    case 42: BINARY_LOOP(p / q) break;
    case 55: BINARY_LOOP(max_f(p, q)) break;
    case 57: BINARY_LOOP(min_f(p, q)) break;
    case 99: BINARY_LOOP((p - q) * (p - q)) break;
    case 90: BINARY_LOOP(floorf(p / q)) break;
    case 95: BINARY_LOOP(floor_mod(p, q)) break;
    default: return 0;
    }
    return 1;
}

void soda_matmul_f32(const float *x, const float *y, float *out, int rows, int cols, int depth, long li, long lk,
                     long rj, long rk, float *scratch) {
    // y as [depth, cols] rows, so that a row of outputs takes each product in turn.
    if (rj != 1) {
        for (int k = 0; k < depth; k++)
            for (int j = 0; j < cols; j++) scratch[(long)k * cols + j] = y[j * rj + k * rk];
        y = scratch;
        rk = cols;
    }
    for (int i = 0; i < rows; i++) {
        float *restrict o = out + (long)i * cols;
        for (int j = 0; j < cols; j++) o[j] = 0;
        for (int k = 0; k < depth; k++) {
            const float a = x[i * li + k * lk];
            const float *restrict b = y + k * rk;
            for (int j = 0; j < cols; j++) o[j] += a * b[j];
        }
    }
}

void soda_rescale(float *restrict out, const int32_t *restrict dots, const int32_t *restrict row_sums,
                  const float *restrict scales, float factor, int32_t offset, int units, int sparse, int asymmetric) {
    if (sparse) {
        if (asymmetric) {
            const float zero_share = factor * (float)offset;
            if (scales)
                for (int u = 0; u < units; u++) out[u] -= (zero_share * scales[u]) * (float)row_sums[u];
            else
                for (int u = 0; u < units; u++) out[u] -= zero_share * (float)row_sums[u];
        }
        if (scales)
            for (int u = 0; u < units; u++) out[u] += (float)dots[u] * (factor * scales[u]);
        else
            for (int u = 0; u < units; u++) out[u] += (float)dots[u] * factor;
    } else if (scales) {
        for (int u = 0; u < units; u++) out[u] += (float)(dots[u] - row_sums[u] * offset) * (factor * scales[u]);
    } else {
        for (int u = 0; u < units; u++) out[u] += (float)(dots[u] - row_sums[u] * offset) * factor;
    }
}
