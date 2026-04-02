/*
 * weight_loader.c — Load trained weights into per-lane BRAM via AXI-Lite CSR
 *
 * Phase 1 (PL-only): Writes weights one-at-a-time through the CSR interface.
 * Phase 3 (AIE): Replace with DMA bulk transfer to DDR4 + AIE memory windows.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "weight_loader.h"
#include "lane_manager.h"

/* Must match versal_config.svh */
#define RC_NODES_MAX    512
#define RC_FEAT_MAX     128
#define RC_WRES_SLOTS   8
#define BICKY_OUT_MAX   64

/* CSR base and stride — must match main.c */
#define LANE_CSR_BASE   0xA0000000ULL
#define LANE_CSR_STRIDE 0x00010000ULL

/* CSR register offsets for weight loading */
#define REG_WIN_WE      0x100
#define REG_WIN_ADDR    0x104
#define REG_WIN_VALUE   0x108
#define REG_WRES_WE     0x10C
#define REG_WRES_ADDR   0x110
#define REG_WRES_VALUE  0x114
#define REG_VOUT_WE     0x118
#define REG_VOUT_ADDR   0x11C
#define REG_VOUT_VALUE  0x120

static inline void reg_write(uint64_t addr, uint32_t val)
{
    volatile uint32_t *ptr = (volatile uint32_t *)(uintptr_t)addr;
    *ptr = val;
}

/*
 * Write a single W_in weight to a lane.
 * addr format: [31:16] = node, [15:0] = feature
 */
static void write_win(uint64_t base, uint16_t node, uint16_t feat, int16_t value)
{
    uint32_t addr = ((uint32_t)node << 16) | feat;
    reg_write(base + REG_WIN_ADDR,  addr);
    reg_write(base + REG_WIN_VALUE, (uint32_t)(uint16_t)value);
    reg_write(base + REG_WIN_WE,    1);
    reg_write(base + REG_WIN_WE,    0);
}

/*
 * Write a single V_out weight to a lane (Bicky output layer).
 * addr format: [31:16] = output_dim, [15:0] = node
 */
static void write_vout(uint64_t base, uint16_t out_dim, uint16_t node, int16_t value)
{
    uint32_t addr = ((uint32_t)out_dim << 16) | node;
    reg_write(base + REG_VOUT_ADDR,  addr);
    reg_write(base + REG_VOUT_VALUE, (uint32_t)(uint16_t)value);
    reg_write(base + REG_VOUT_WE,    1);
    reg_write(base + REG_VOUT_WE,    0);
}

int load_weights_for_lane(int lane_id, const char *filepath)
{
    FILE *fp = fopen(filepath, "rb");
    if (!fp) {
        printf("[weight_loader] Cannot open %s\n", filepath);
        return -1;
    }

    uint64_t base = LANE_CSR_BASE + (lane_id * LANE_CSR_STRIDE);

    /* Read file header: magic, nodes, features, outputs */
    uint32_t header[4];
    if (fread(header, sizeof(uint32_t), 4, fp) != 4) {
        printf("[weight_loader] Invalid header in %s\n", filepath);
        fclose(fp);
        return -1;
    }

    if (header[0] != 0x57454947) {  /* "WEIG" magic */
        printf("[weight_loader] Bad magic: 0x%08x (expected 0x57454947)\n", header[0]);
        fclose(fp);
        return -1;
    }

    uint32_t nodes    = header[1];
    uint32_t features = header[2];
    uint32_t outputs  = header[3];

    if (nodes > RC_NODES_MAX || features > RC_FEAT_MAX || outputs > BICKY_OUT_MAX) {
        printf("[weight_loader] Dimensions too large: N=%u K=%u O=%u\n",
               nodes, features, outputs);
        fclose(fp);
        return -1;
    }

    printf("[weight_loader] Lane %d: loading %ux%u W_in + %ux%u V_out from %s\n",
           lane_id, nodes, features, outputs, nodes, filepath);

    /* Load W_in: nodes x features int16 values */
    for (uint32_t n = 0; n < nodes; n++) {
        for (uint32_t f = 0; f < features; f++) {
            int16_t val;
            if (fread(&val, sizeof(int16_t), 1, fp) != 1) {
                printf("[weight_loader] Truncated W_in at node=%u feat=%u\n", n, f);
                fclose(fp);
                return -1;
            }
            write_win(base, n, f, val);
        }
    }

    /* Load V_out: outputs x nodes int16 values (if present) */
    for (uint32_t o = 0; o < outputs; o++) {
        for (uint32_t n = 0; n < nodes; n++) {
            int16_t val;
            if (fread(&val, sizeof(int16_t), 1, fp) != 1) {
                /* V_out may not be present for RC-only configs */
                break;
            }
            write_vout(base, o, n, val);
        }
    }

    fclose(fp);
    printf("[weight_loader] Lane %d: weights loaded successfully\n", lane_id);
    return 0;
}
