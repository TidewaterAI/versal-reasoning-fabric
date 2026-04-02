/*
 * main.c — Versal Reasoning Fabric PS application (Cortex-A72)
 *
 * Initializes the reasoning fabric:
 *   1. Load trained weights from SD card or DDR into per-lane BRAM/AIE memory
 *   2. Configure lane parameters (node count, features, alpha, mode)
 *   3. Enable lanes and start DMA streaming
 *   4. Monitor fabric health (watchdog, faults, duty counts)
 *
 * Build:
 *   This is a baremetal or Linux application for the Versal A72.
 *   In Vitis, create a platform from the XSA exported by Vivado,
 *   then create an application project pointing to this source.
 *
 * For Linux deployment, compile with:
 *   aarch64-linux-gnu-gcc -O2 -o fabric_ctrl main.c weight_loader.c lane_manager.c
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "weight_loader.h"
#include "lane_manager.h"

/* AXI-Lite base addresses (from Vivado address editor) */
/* These will change based on your block design — update after BD wiring */
#define LANE_CSR_BASE       0xA0000000ULL
#define LANE_CSR_STRIDE     0x00010000ULL  /* 64 KB per lane */
#define GLOBAL_SAFETY_BASE  0xA0100000ULL
#define DMA_BASE            0xA0200000ULL

#define NUM_LANES           4

/* Register offsets within each lane CSR bank */
#define REG_LANE_ENABLE     0x00
#define REG_MODE_BICKY      0x04
#define REG_RC_NODES        0x08
#define REG_RC_FEAT_K       0x0C
#define REG_RC_ALPHA        0x10
#define REG_RC_RHO          0x14
#define REG_TICK_BUDGET     0x18
#define REG_LANE_STATUS     0x1C
#define REG_LANE_FAULT      0x20

/* Global safety registers */
#define REG_KILL_LATCHED    0x00
#define REG_DUTY_COUNT      0x04
#define REG_FABRIC_FAULT    0x08

/*
 * Write a 32-bit value to a memory-mapped register.
 * On baremetal, this is a direct pointer dereference.
 * On Linux, replace with mmap'd /dev/mem or UIO access.
 */
static inline void reg_write(uint64_t addr, uint32_t val)
{
    volatile uint32_t *ptr = (volatile uint32_t *)(uintptr_t)addr;
    *ptr = val;
}

static inline uint32_t reg_read(uint64_t addr)
{
    volatile uint32_t *ptr = (volatile uint32_t *)(uintptr_t)addr;
    return *ptr;
}

static void configure_lane(int lane_id, const lane_config_t *cfg)
{
    uint64_t base = LANE_CSR_BASE + (lane_id * LANE_CSR_STRIDE);

    /* Disable lane before reconfiguring */
    reg_write(base + REG_LANE_ENABLE, 0);

    reg_write(base + REG_MODE_BICKY,  cfg->mode_bicky);
    reg_write(base + REG_RC_NODES,    cfg->rc_nodes);
    reg_write(base + REG_RC_FEAT_K,   cfg->rc_feat_k);
    reg_write(base + REG_RC_ALPHA,    cfg->rc_alpha_q15);
    reg_write(base + REG_RC_RHO,      cfg->rc_rho_q15);
    reg_write(base + REG_TICK_BUDGET, cfg->tick_budget);

    printf("[lane %d] Configured: nodes=%u, feat=%u, alpha=0x%04x, mode=%s\n",
           lane_id, cfg->rc_nodes, cfg->rc_feat_k, cfg->rc_alpha_q15,
           cfg->mode_bicky ? "bicky" : "rc");
}

static void enable_lane(int lane_id)
{
    uint64_t base = LANE_CSR_BASE + (lane_id * LANE_CSR_STRIDE);
    reg_write(base + REG_LANE_ENABLE, 1);
    printf("[lane %d] Enabled\n", lane_id);
}

static int check_fabric_health(void)
{
    uint32_t kill   = reg_read(GLOBAL_SAFETY_BASE + REG_KILL_LATCHED);
    uint32_t duty   = reg_read(GLOBAL_SAFETY_BASE + REG_DUTY_COUNT);
    uint32_t fault  = reg_read(GLOBAL_SAFETY_BASE + REG_FABRIC_FAULT);

    if (kill) {
        printf("[SAFETY] Kill latched! duty_count=%u\n", duty);
        return -1;
    }
    if (fault) {
        printf("[SAFETY] Fabric fault detected (0x%08x)\n", fault);
        return -1;
    }
    return 0;
}

int main(void)
{
    printf("=== Versal Reasoning Fabric Controller ===\n");
    printf("Lanes: %d\n\n", NUM_LANES);

    /* Check safety state before doing anything */
    if (check_fabric_health() != 0) {
        printf("ERROR: Fabric in fault state at startup. Reset required.\n");
        return 1;
    }

    /* Default lane configuration (RC mode, 256 nodes, 13 features) */
    lane_config_t default_cfg = {
        .mode_bicky   = 0,
        .rc_nodes     = 256,
        .rc_feat_k    = 13,
        .rc_alpha_q15 = 0x2666,  /* ~0.3 in Q1.15 */
        .rc_rho_q15   = 0x7333,  /* ~0.9 in Q1.15 */
        .tick_budget  = 131072,
    };

    /* Configure and load weights for each lane */
    for (int i = 0; i < NUM_LANES; i++) {
        configure_lane(i, &default_cfg);

        /* Load RC weights (W_in and W_res) from file */
        int rc = load_weights_for_lane(i, "weights/rc_lane_default.bin");
        if (rc != 0) {
            printf("[lane %d] WARNING: Weight load failed (rc=%d), using defaults\n", i, rc);
        }
    }

    /* Enable all lanes */
    for (int i = 0; i < NUM_LANES; i++) {
        enable_lane(i);
    }

    printf("\nFabric running. Monitoring health...\n");

    /* Main monitoring loop */
    while (1) {
        if (check_fabric_health() != 0) {
            printf("Fabric fault — disabling all lanes\n");
            for (int i = 0; i < NUM_LANES; i++) {
                uint64_t base = LANE_CSR_BASE + (i * LANE_CSR_STRIDE);
                reg_write(base + REG_LANE_ENABLE, 0);
            }
            return 1;
        }

        /* Print lane status periodically */
        for (int i = 0; i < NUM_LANES; i++) {
            uint64_t base = LANE_CSR_BASE + (i * LANE_CSR_STRIDE);
            uint32_t status = reg_read(base + REG_LANE_STATUS);
            uint32_t fault  = reg_read(base + REG_LANE_FAULT);
            if (fault) {
                printf("[lane %d] FAULT: 0x%08x\n", i, fault);
            }
        }

        /* Sleep 1 second (platform-specific) */
        /* On baremetal: busy-wait or timer interrupt */
        /* On Linux: sleep(1); */
    }

    return 0;
}
