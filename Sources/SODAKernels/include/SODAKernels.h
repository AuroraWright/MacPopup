#ifndef SODA_KERNELS_H
#define SODA_KERNELS_H

#include <stdint.h>

/// out[b·units + u] = Σ_k x[b·n + k] · w[u·n + k] for b < batch, u < units, in 32-bit integers.
void soda_dot_s8(const int8_t *x, int batch, const int8_t *w, int units, int n, int32_t *out);

/// The same with 4-bit weights, two a byte (the first in the low nibble), n / 2 bytes a row; n even.
void soda_dot_s4(const int8_t *x, int batch, const uint8_t *w, int units, int n, int32_t *out);

/// The same with 1×16 block-sparse weights: row u holds the 16-column blocks indices[segments[u] ..< segments[u + 1]],
/// their values 16 at a time in that order. out[b·units + u] = Σ over the row's blocks j of
/// Σ_c x[b·n + 16·indices[j] + c] · values[16·j + c]. The indices are unsigned, `index_size` (1, 2 or 4) bytes each.
/// `scratch`: room for 4·(⌊blocks / 2⌋ + 2) int32s (blocks: segments[units]).
void soda_sparse_dot_s8(const int8_t *x, int batch, const int8_t *values, const int32_t *segments,
                        const void *indices, int index_size, int units, int n, int32_t *out, int32_t *scratch);

/// Whether x[0 ..< n] are all zero.
int soda_all_zero(const float *x, long n);

/// TFLite's NeonSymmetricQuantizeFloats on one row: q = x scaled to ±127 by its largest magnitude (rounded half away
/// from zero); returns the scale back (1 for an all-zero row).
float soda_quantize_symmetric(const float *x, int n, int8_t *q);

/// TFLite's NeonAsymmetricQuantizeFloats on one row: the row's range mapped to -128...127 with a zero point (the
/// difference in float, the rest in double). Sets the scale and zero point (1 and 0 for a constant row).
void soda_quantize_asymmetric(const float *x, int n, int8_t *q, float *scale, int32_t *zero);

/// Eigen's float LOGISTIC, TANH and packet exp (see EigenMath in Kernels.swift) of x[0 ..< n].
void soda_logistic(const float *x, float *out, long n);
void soda_tanh(const float *x, float *out, long n);
void soda_packet_exp(const float *x, float *out, long n);

/// The float binary ops (TFLite's builtin codes: ADD 0, MUL 18, SUB 41, DIV 42, MAXIMUM 55, MINIMUM 57,
/// SQUARED_DIFFERENCE 99, FLOOR_DIV 90, FLOOR_MOD 95) over `outer` rows of `inner` values: out[i·inner + j] =
/// f(x[i·x_outer + j·x_inner], y[i·y_outer + j·y_inner]), the inner strides 0 or 1. Returns 0 for another op.
int soda_binary(int op, const float *x, long x_outer, int x_inner, const float *y, long y_outer, int y_inner,
                float *out, long outer, long inner);

/// A float matrix product as TFLite's reference BATCH_MATMUL computes it, each output summing its products in order
/// from 0: out[i·cols + j] = Σ_k x[i·li + k·lk] · y[j·rj + k·rk]. `scratch` holds depth·cols floats when rj ≠ 1.
void soda_matmul_f32(const float *x, const float *y, float *out, int rows, int cols, int depth, long li, long lk,
                     long rj, long rk, float *scratch);

/// A hybrid layer's scaling back of one input row's integer sums (`scales` null: per-tensor, the factor including it).
/// Dense: out[u] += (float)(dots[u] − row_sums[u]·offset) · (factor · scales[u]). Sparse (TFLite's sparse sdot
/// kernel): out[u] −= (factor · offset · scales[u]) · row_sums[u] when asymmetric, then out[u] += dots[u] · (factor ·
/// scales[u]).
void soda_rescale(float *out, const int32_t *dots, const int32_t *row_sums, const float *scales, float factor,
                  int32_t offset, int units, int sparse, int asymmetric);

/// out[r] = Σ_k w[r·n + k] for r < rows.
void soda_row_sums_s8(const int8_t *w, long rows, int n, int32_t *out);

/// A depthwise convolution's integer sums for one image (NHWC, depth multiplier 1): acc[(oy·outW + ox)·channels + c] =
/// Σ over the filter taps inside the image of w[(ky·fw + kx)·channels + c] · (q[(iy·width + ix)·channels + c] − zero).
void soda_depthwise_s8(const int8_t *q, int zero, int height, int width, int channels, const int8_t *w, int fh, int fw,
                       int stride_h, int stride_w, int dilation_h, int dilation_w, int pad_h, int pad_w, int out_h,
                       int out_w, int32_t *acc);

#endif
