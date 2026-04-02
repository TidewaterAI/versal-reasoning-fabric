// EXPERIMENTAL — Not yet compiled or validated. See aie/README.md.
//
// rc_update.cc — Reservoir Computing leaky integration + tanh activation.
//
// Matches the behavior of rc_core.sv's UP_COMMIT phase:
//   prev = state_mem[i]
//   tanh_out = tanh_lookup(acc_work)
//   leak_term = prev * (1 - alpha) >> 15
//   drive_term = tanh_out * alpha >> 15
//   new_state = saturate(leak_term + drive_term)

#include "rc_update.h"
#include <aie_api/aie.hpp>
#include <aie_api/aie_adf.hpp>

// Piecewise linear tanh approximation for Q1.15
// Covers range [-3.0, 3.0] in Q1.15 space ([-98304, 98304] in raw int16,
// but we only see values in [-32768, 32767] due to Q1.15 saturation).
//
// Uses a 4-segment piecewise linear approximation:
//   |x| < 0.25 (8192):  tanh(x) ≈ x
//   |x| < 1.0 (32767):  tanh(x) ≈ 0.84 * x + 0.16 * sign(x) * 8192
//   |x| >= 1.0:          tanh(x) ≈ sign(x) * 0.96 * 32767
//
// This is simpler than the 64-entry LUT in rc_core.sv but sufficient for
// the AIE's throughput-optimized pipeline. Accuracy can be improved with
// more segments if needed.
static inline int16_t tanh_q15(int16_t x) {
    int32_t abs_x = (x < 0) ? -static_cast<int32_t>(x) : static_cast<int32_t>(x);
    int32_t result;

    if (abs_x < 8192) {
        // Near-linear region: tanh(x) ≈ x
        result = x;
    } else if (abs_x < 24576) {
        // Mid region: tanh(x) ≈ 0.83x + 0.17*sign(x)*8192
        // 0.83 in Q1.15 = 27197, 0.17 * 8192 = 1393
        int32_t scaled = (static_cast<int32_t>(x) * 27197) >> 15;
        result = scaled + ((x > 0) ? 1393 : -1393);
    } else {
        // Saturation region: tanh(x) ≈ ±0.96
        // 0.96 in Q1.15 = 31457
        result = (x > 0) ? 31457 : -31457;
    }

    // Saturate to Q1.15
    if (result > 32767) result = 32767;
    if (result < -32768) result = -32768;
    return static_cast<int16_t>(result);
}

void rc_update_kernel(
    input_buffer<int16, extents<ROW_TILE>>& __restrict drive,
    input_buffer<int16, extents<ROW_TILE>>& __restrict prev_state,
    output_buffer<int16, extents<ROW_TILE>>& __restrict new_state,
    int16_t alpha_q15
) {
    auto p_drive = aie::begin(drive);
    auto p_prev  = aie::begin(prev_state);
    auto p_out   = aie::begin(new_state);

    int32_t one_minus_alpha = 32767 - static_cast<int32_t>(alpha_q15);
    int32_t alpha_32 = static_cast<int32_t>(alpha_q15);

    for (int i = 0; i < ROW_TILE; i++) {
        int16_t d = *p_drive++;
        int16_t s = *p_prev++;

        // Apply tanh activation to drive signal
        int16_t activated = tanh_q15(d);

        // Leaky integration
        int32_t leak_term  = (static_cast<int32_t>(s) * one_minus_alpha) >> Q15_SHIFT;
        int32_t drive_term = (static_cast<int32_t>(activated) * alpha_32) >> Q15_SHIFT;
        int32_t mixed = leak_term + drive_term;

        // Saturate
        if (mixed > 32767) mixed = 32767;
        if (mixed < -32768) mixed = -32768;

        *p_out++ = static_cast<int16_t>(mixed);
    }
}
