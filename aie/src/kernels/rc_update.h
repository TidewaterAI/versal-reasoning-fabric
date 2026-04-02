// EXPERIMENTAL — Not yet compiled or validated. See aie/README.md.
//
// rc_update.h — Reservoir Computing state update kernel for Versal AI Engine.
//
// Implements the leaky integration equation:
//   state[i] = (1 - alpha) * state[i] + alpha * tanh(drive[i])
//
// where drive[i] = sum(W_in[i][j] * feat[j]) + sum(W_res[i][k] * state[k])
//
// The heavy matrix-vector products (W_in * feat and W_res * state) are handled
// by separate matvec_q15 kernel invocations in the AIE graph. This kernel
// performs the final activation (tanh) and leaky integration step.
//
// Input:
//   - drive: ROW_TILE int16 values (output of W_in*feat + W_res*state matvec)
//   - prev_state: ROW_TILE int16 values (previous reservoir state)
//   - alpha_q15: leak rate in Q1.15 (single value, broadcast)
//
// Output:
//   - new_state: ROW_TILE int16 values (updated reservoir state)

#ifndef RC_UPDATE_H
#define RC_UPDATE_H

#include <adf.h>
#include "matvec_q15.h"  // ROW_TILE, Q15_SHIFT

void rc_update_kernel(
    input_buffer<int16, extents<ROW_TILE>>& __restrict drive,
    input_buffer<int16, extents<ROW_TILE>>& __restrict prev_state,
    output_buffer<int16, extents<ROW_TILE>>& __restrict new_state,
    int16_t alpha_q15
);

#endif // RC_UPDATE_H
