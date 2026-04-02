/*
 * lane_manager.h — Lane configuration and runtime management
 */

#ifndef LANE_MANAGER_H
#define LANE_MANAGER_H

#include <stdint.h>

typedef struct {
    uint32_t mode_bicky;      /* 0 = RC, 1 = Bicky */
    uint32_t rc_nodes;        /* Reservoir node count (1-512) */
    uint32_t rc_feat_k;       /* Feature input dimension (1-128) */
    uint16_t rc_alpha_q15;    /* Leak rate in Q1.15 */
    uint16_t rc_rho_q15;      /* Spectral radius in Q1.15 */
    uint32_t tick_budget;     /* Max clock cycles per inference */
} lane_config_t;

#endif /* LANE_MANAGER_H */
