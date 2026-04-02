// EXPERIMENTAL — Not yet compiled or validated. See aie/README.md.
//
// reasoning_graph.h — Top-level AIE graph for the parallel reasoning fabric.
//
// Instantiates NUM_RC_LANES rc_lane_graph instances, each consuming one lane's
// feature vectors and producing updated state vectors. The PL side manages
// state buffering and mode switching (RC vs Bicky).
//
// This graph is instantiated in the Vivado block design and connected to the
// PL via PLIO interfaces. Each PLIO maps to an AXI-Stream port in versal_top.sv.
//
// Scaling: with ROW_TILE=32 and 256-node reservoirs, each lane needs
// ceil(256/32) = 8 matvec tile invocations for W_in and 8 for W_res = 16 total.
// Each matvec kernel occupies ~0.7 of a tile, so each lane needs ~12 AIE tiles.
// The XCVC1902 has 400 tiles, supporting ~32 lanes in AIE.
//
// For Phase 1 (PL-only), this graph is not instantiated and all compute
// runs in PL-local rc_core and bicky_inference modules.

#ifndef REASONING_GRAPH_H
#define REASONING_GRAPH_H

#include <adf.h>
#include "rc_graph.h"

using namespace adf;

// Number of lanes to instantiate in AIE.
// Must match VERSAL_NUM_LANES in versal_config.svh when USE_AIE=1.
constexpr int NUM_RC_LANES = 4;

class reasoning_fabric_graph : public graph {
public:
    // Per-lane PLIO connections (matched to versal_top.sv port arrays)
    input_plio  lane_features[NUM_RC_LANES];
    input_plio  lane_prev_state[NUM_RC_LANES];
    output_plio lane_new_state[NUM_RC_LANES];

    // Per-lane RC subgraphs
    rc_lane_graph rc_lanes[NUM_RC_LANES];

    reasoning_fabric_graph() {
        for (int i = 0; i < NUM_RC_LANES; i++) {
            // Create PLIOs with unique names for block design connection
            std::string feat_name  = "lane" + std::to_string(i) + "_feat";
            std::string state_name = "lane" + std::to_string(i) + "_state";
            std::string out_name   = "lane" + std::to_string(i) + "_out";

            lane_features[i]   = input_plio::create(feat_name,  plio_64_bits, "data/lane" + std::to_string(i) + "_feat.txt");
            lane_prev_state[i] = input_plio::create(state_name, plio_64_bits, "data/lane" + std::to_string(i) + "_state.txt");
            lane_new_state[i]  = output_plio::create(out_name,  plio_64_bits, "data/lane" + std::to_string(i) + "_out.txt");

            // Wire PLIOs to subgraph ports
            connect(lane_features[i].out[0],   rc_lanes[i].in_features.out[0]);
            connect(lane_prev_state[i].out[0], rc_lanes[i].in_prev_state.out[0]);
            connect(rc_lanes[i].out_new_state.in[0], lane_new_state[i].in[0]);
        }
    }
};

#endif // REASONING_GRAPH_H
