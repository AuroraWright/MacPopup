#ifndef ONEOCR_KERNELS_H
#define ONEOCR_KERNELS_H

#include <stdint.h>

/// out[r] = Σ_k q[k] · w[r·n + k] for r < rows, in 32-bit integers. n must be a multiple of 16.
void oneocr_dot_u8_rows(const uint8_t *q, const uint8_t *w, int rows, int n, uint32_t *out);

/// The same for four vectors q + j·n (j < 4): out[j·rows + r] = Σ_k q[j·n + k] · w[r·n + k].
void oneocr_dot_u8_rows4(const uint8_t *q, const uint8_t *w, int rows, int n, uint32_t *out);

#endif
