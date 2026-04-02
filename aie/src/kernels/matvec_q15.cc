// EXPERIMENTAL — Not yet compiled or validated. See aie/README.md.
//
// matvec_q15.cc — Q1.15 matrix-vector multiply kernel for Versal AI Engine.
//
// Uses AIE vector intrinsics for 8-wide SIMD multiply-accumulate.
// Each invocation processes ROW_TILE rows of the weight matrix against the
// full input vector, producing ROW_TILE output values.
//
// Performance target: ROW_TILE=32, COLS=128 -> 512 MAC cycles + overhead.
// At 1 GHz AIE clock, this is ~0.5 us per tile invocation.

#include "matvec_q15.h"
#include <aie_api/aie.hpp>
#include <aie_api/aie_adf.hpp>

void matvec_q15_kernel(
    input_buffer<int16, extents<ROW_TILE * MAX_COLS>>& __restrict weights,
    input_buffer<int16, extents<MAX_COLS>>& __restrict input_vec,
    output_buffer<int16, extents<ROW_TILE>>& __restrict output_vec
) {
    // Get iterators
    auto p_w   = aie::begin(weights);
    auto p_in  = aie::begin(input_vec);
    auto p_out = aie::begin(output_vec);

    // Load full input vector into register file
    // Process in chunks of 8 (v8int16 = 128 bits)
    constexpr int VEC_LEN = 8;
    constexpr int NUM_CHUNKS = MAX_COLS / VEC_LEN;

    // Cache input vector in local array for reuse across rows
    aie::vector<int16, VEC_LEN> in_chunks[NUM_CHUNKS];
    {
        auto p_in_iter = aie::begin(input_vec);
        for (int c = 0; c < NUM_CHUNKS; c++) {
            in_chunks[c] = aie::load_v<VEC_LEN>(p_in_iter);
            p_in_iter += VEC_LEN;
        }
    }

    // Process each row
    for (int row = 0; row < ROW_TILE; row++) {
        // Accumulator for this row (32-bit to prevent overflow)
        aie::accum<acc48, VEC_LEN> acc;
        acc = aie::zeros<acc48, VEC_LEN>();

        int32_t row_sum = 0;

        // MAC across all column chunks
        for (int c = 0; c < NUM_CHUNKS; c++) {
            // Load weight chunk for this row
            aie::vector<int16, VEC_LEN> w_chunk = aie::load_v<VEC_LEN>(p_w);
            p_w += VEC_LEN;

            // Multiply and accumulate
            acc = aie::mac(acc, w_chunk, in_chunks[c]);
        }

        // Reduce the vector accumulator to a scalar sum
        // Each element of acc contains a partial sum; we need the total
        auto acc_vec = acc.to_vector<int32>(0);  // Extract as int32
        for (int i = 0; i < VEC_LEN; i++) {
            row_sum += acc_vec[i];
        }

        // Shift right by Q15_SHIFT to convert Q2.30 product back to Q1.15
        int32_t result = row_sum >> Q15_SHIFT;

        // Saturate to Q1.15 range [-32768, 32767]
        if (result > 32767) result = 32767;
        if (result < -32768) result = -32768;

        // Store output
        *p_out++ = static_cast<int16_t>(result);
    }
}
