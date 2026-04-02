/*
 * weight_loader.h — Load trained weights into per-lane BRAM or AIE memory
 */

#ifndef WEIGHT_LOADER_H
#define WEIGHT_LOADER_H

#include <stdint.h>

/*
 * load_weights_for_lane — Load a weight binary file into a lane's weight memory.
 *
 * The weight file format is a flat array of Q1.15 (int16_t) values laid out as:
 *   W_in:   [NODES_MAX * FEAT_MAX] int16 values (row-major)
 *   W_res:  [NODES_MAX * WRES_SLOTS] int16 values + column indices
 *   V_out:  [OUT_MAX * NODES_MAX] int16 values (Bicky output weights)
 *
 * For Phase 1 (PL-only), weights are written via AXI-Lite CSR registers
 * using the win_we/win_addr/win_value interface in lane_tile.sv.
 *
 * For Phase 3 (AIE), weights are DMA'd to DDR4 and then loaded into
 * AIE local memory windows by the AIE runtime.
 *
 * @param lane_id   Lane index (0 to NUM_LANES-1)
 * @param filepath  Path to weight binary file
 * @return 0 on success, -1 on file error, -2 on DMA error
 */
int load_weights_for_lane(int lane_id, const char *filepath);

#endif /* WEIGHT_LOADER_H */
