#include "OneOCRKernels.h"

#include <arm_neon.h>

void oneocr_dot_u8_rows(const uint8_t *q, const uint8_t *w, int rows, int n, uint32_t *out) {
    for (int r = 0; r < rows; r++) {
        const uint8_t *wr = w + (long)r * n;
        uint32x4_t acc0 = vdupq_n_u32(0), acc1 = vdupq_n_u32(0);
        int k = 0;
        for (; k + 32 <= n; k += 32) {
            acc0 = vdotq_u32(acc0, vld1q_u8(q + k), vld1q_u8(wr + k));
            acc1 = vdotq_u32(acc1, vld1q_u8(q + k + 16), vld1q_u8(wr + k + 16));
        }
        for (; k < n; k += 16) acc0 = vdotq_u32(acc0, vld1q_u8(q + k), vld1q_u8(wr + k));
        out[r] = vaddvq_u32(vaddq_u32(acc0, acc1));
    }
}

void oneocr_dot_u8_rows4(const uint8_t *q, const uint8_t *w, int rows, int n, uint32_t *out) {
    int r = 0;
    // Four rows at a time: each load feeds four products rather than one or two.
    for (; r + 4 <= rows; r += 4) {
        const uint8_t *w0 = w + (long)r * n, *w1 = w0 + n, *w2 = w1 + n, *w3 = w2 + n;
        uint32x4_t a[4][4];
        for (int j = 0; j < 4; j++)
            for (int i = 0; i < 4; i++) a[j][i] = vdupq_n_u32(0);
        for (int k = 0; k < n; k += 16) {
            uint8x16_t v0 = vld1q_u8(w0 + k), v1 = vld1q_u8(w1 + k), v2 = vld1q_u8(w2 + k), v3 = vld1q_u8(w3 + k);
            for (int j = 0; j < 4; j++) {
                uint8x16_t x = vld1q_u8(q + (long)j * n + k);
                a[j][0] = vdotq_u32(a[j][0], x, v0);
                a[j][1] = vdotq_u32(a[j][1], x, v1);
                a[j][2] = vdotq_u32(a[j][2], x, v2);
                a[j][3] = vdotq_u32(a[j][3], x, v3);
            }
        }
        for (int j = 0; j < 4; j++)
            for (int i = 0; i < 4; i++) out[(long)j * rows + r + i] = vaddvq_u32(a[j][i]);
    }
    for (; r < rows; r++) {
        const uint8_t *wr = w + (long)r * n;
        uint32x4_t a0 = vdupq_n_u32(0), a1 = vdupq_n_u32(0), a2 = vdupq_n_u32(0), a3 = vdupq_n_u32(0);
        for (int k = 0; k < n; k += 16) {
            uint8x16_t wv = vld1q_u8(wr + k);
            a0 = vdotq_u32(a0, vld1q_u8(q + k), wv);
            a1 = vdotq_u32(a1, vld1q_u8(q + n + k), wv);
            a2 = vdotq_u32(a2, vld1q_u8(q + 2 * n + k), wv);
            a3 = vdotq_u32(a3, vld1q_u8(q + 3 * n + k), wv);
        }
        out[r] = vaddvq_u32(a0);
        out[rows + r] = vaddvq_u32(a1);
        out[2 * rows + r] = vaddvq_u32(a2);
        out[3 * rows + r] = vaddvq_u32(a3);
    }
}
