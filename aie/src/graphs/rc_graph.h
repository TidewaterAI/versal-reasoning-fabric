// EXPERIMENTAL — Not yet compiled or validated. See aie/README.md.
//
// rc_graph.h — AIE dataflow graph for one RC (Reservoir Computing) lane.
//
// Implements the full RC state update pipeline:
//   1. matvec_win: W_in * features (input projection)
//   2. matvec_wres: W_res * prev_state (recurrent projection)
//   3. element-wise add of (1) and (2) to form drive signal
//   4. rc_update: tanh activation + leaky integration
//
// Each graph instance consumes one lane's feature vectors and produces
// updated state vectors. Multiple instances run in parallel for multi-lane.
//
// PL-side connection:
//   - Feature vectors arrive via PLIO from lane_tile
//   - Updated state vectors return via PLIO to lane_tile
//   - Weight matrices loaded from DDR via DMA before inference begins

#ifndef RC_GRAPH_H
#define RC_GRAPH_H

#include <adf.h>
#include "../kernels/matvec_q15.h"
#include "../kernels/rc_update.h"

using namespace adf;

class rc_lane_graph : public graph {
public:
    // External connections (to PL via PLIO)
    input_plio  in_features;    // Feature vector from lane_tile
    input_plio  in_prev_state;  // Previous state from PL-side state buffer
    output_plio out_new_state;  // Updated state to PL-side state buffer

    // Kernels
    kernel k_matvec_win;    // W_in * features
    kernel k_matvec_wres;   // W_res * prev_state
    kernel k_rc_update;     // tanh + leaky integration

    rc_lane_graph() {
        // Create kernel instances
        k_matvec_win  = kernel::create(matvec_q15_kernel);
        k_matvec_wres = kernel::create(matvec_q15_kernel);
        k_rc_update   = kernel::create(rc_update_kernel);

        // Source file locations
        source(k_matvec_win)  = "kernels/matvec_q15.cc";
        source(k_matvec_wres) = "kernels/matvec_q15.cc";
        source(k_rc_update)   = "kernels/rc_update.cc";

        // Runtime ratios (fraction of AIE tile time this kernel uses)
        // Each matvec processes 32 rows x 128 cols = 4096 MACs
        // At 8 MACs/cycle (v8int16), that's ~512 cycles per invocation
        // With overhead, estimate ~0.7 of tile time
        runtime<ratio>(k_matvec_win)  = 0.7;
        runtime<ratio>(k_matvec_wres) = 0.7;
        runtime<ratio>(k_rc_update)   = 0.3;

        // Connect PLIO to kernels
        // Features -> W_in matvec (as input vector)
        connect(in_features.out[0], k_matvec_win.in[1]);

        // Previous state -> W_res matvec (as input vector)
        connect(in_prev_state.out[0], k_matvec_wres.in[1]);

        // W_in weights are loaded into kernel memory via async DMA
        // (configured at runtime by PS, not wired in the graph)

        // Matvec outputs -> RC update
        // Drive = W_in * feat + W_res * state (addition done in rc_update)
        connect(k_matvec_win.out[0], k_rc_update.in[0]);

        // Previous state also feeds rc_update for leaky integration
        connect(in_prev_state.out[0], k_rc_update.in[1]);

        // RC update output -> PLIO back to PL
        connect(k_rc_update.out[0], out_new_state.in[0]);

        // Buffer sizes
        dimensions(k_matvec_win.in[1])  = {MAX_COLS};
        dimensions(k_matvec_win.out[0]) = {ROW_TILE};
        dimensions(k_matvec_wres.in[1]) = {MAX_COLS};
        dimensions(k_matvec_wres.out[0])= {ROW_TILE};
        dimensions(k_rc_update.in[0])   = {ROW_TILE};
        dimensions(k_rc_update.in[1])   = {ROW_TILE};
        dimensions(k_rc_update.out[0])  = {ROW_TILE};
    }
};

#endif // RC_GRAPH_H
