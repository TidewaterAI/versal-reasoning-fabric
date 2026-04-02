// EXPERIMENTAL — Not yet compiled or validated. See aie/README.md.
//
// matvec_q15.h — Core matrix-vector multiply kernel for Versal AI Engine.
//
// Computes y = W * x in Q1.15 fixed-point using AIE's 128-bit SIMD.
// Each AIE tile processes a ROW_TILE-row slice of the weight matrix.
//
// Data format:
//   - Weights W: Q1.15 (int16), row-major, ROW_TILE x COLS
//   - Input x:   Q1.15 (int16), COLS elements
//   - Output y:  Q1.15 (int16), ROW_TILE elements (saturated from 32-bit accum)
//
// The AIE v16int16 type processes 8 multiplies per cycle (128-bit / 16-bit).
// For COLS=128, each row takes 128/8 = 16 MAC cycles.
// For ROW_TILE=32, one kernel invocation takes 32 * 16 = 512 MAC cycles.

#ifndef MATVEC_Q15_H
#define MATVEC_Q15_H

#include <adf.h>

// Tile size: each AIE tile processes this many rows of the weight matrix.
// Must be a multiple of 8 for SIMD alignment.
constexpr int ROW_TILE = 32;

// Maximum column dimension (input vector length).
// Padded to multiple of 8 for SIMD alignment.
constexpr int MAX_COLS = 128;

// Q1.15 scaling: product of two Q1.15 values is Q2.30; shift right 15 to get Q1.15
constexpr int Q15_SHIFT = 15;

// Kernel function signature.
// weights: ROW_TILE * MAX_COLS int16 values (row-major)
// input:   MAX_COLS int16 values
// output:  ROW_TILE int16 values (saturated Q1.15)
// cols:    actual number of columns (must be <= MAX_COLS, multiple of 8)
void matvec_q15_kernel(
    input_buffer<int16, extents<ROW_TILE * MAX_COLS>>& __restrict weights,
    input_buffer<int16, extents<MAX_COLS>>& __restrict input_vec,
    output_buffer<int16, extents<ROW_TILE>>& __restrict output_vec
);

#endif // MATVEC_Q15_H
