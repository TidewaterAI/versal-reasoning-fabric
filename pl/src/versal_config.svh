`ifndef VERSAL_CONFIG_SVH
`define VERSAL_CONFIG_SVH

// versal_config.svh
// Deployment constants for the Versal VCK190 parallel reasoning fabric.
// Mirrors hub_config.svh pattern from Zybo Z7-20 but scaled for XCVC1902.

// ============================================================================
// Fabric Geometry
// ============================================================================

// Number of parallel reasoning lanes (RC+Bicky pairs).
// Start at 4 for bringup; scale to 16-64 as AIE integration matures.
localparam integer VERSAL_NUM_LANES         = 4;

// Number of instrument input ports (lab equipment streams).
localparam integer VERSAL_NUM_INSTRUMENTS   = 4;

// Total stream router inputs: lanes + instruments + 1 (host DMA ingress)
localparam integer VERSAL_STREAM_INPUTS     = VERSAL_NUM_LANES
                                            + VERSAL_NUM_INSTRUMENTS + 1;

// ============================================================================
// Clock Domains
// ============================================================================

// PL fabric clock (from CIPS output or NoC clock)
localparam integer VERSAL_PL_CLK_HZ        = 250_000_000;  // 250 MHz

// AIE array clock (fixed by silicon)
localparam integer VERSAL_AIE_CLK_HZ       = 1_000_000_000; // 1 GHz

// Timestamp counter reference
localparam integer VERSAL_TS_TICKS_PER_SEC  = VERSAL_PL_CLK_HZ;

// ============================================================================
// Data Path Widths
// ============================================================================

localparam integer VERSAL_AXIS_W            = 64;   // AXI-Stream data width
localparam integer VERSAL_QW                = 16;   // Q1.15 fixed-point width
localparam integer VERSAL_PLIO_W            = 64;   // AIE PLIO width (match AXIS)

// ============================================================================
// Per-Lane Compute Parameters (defaults; runtime-configurable via CSR)
// ============================================================================

// RC core dimensions
localparam integer VERSAL_RC_NODES_MAX      = 512;  // Up from 256 (Zybo)
localparam integer VERSAL_RC_FEAT_MAX       = 128;  // Up from 64
localparam integer VERSAL_RC_WRES_SLOTS     = 8;    // Sparse recurrent slots

// Bicky inference dimensions
localparam integer VERSAL_BICKY_HIDDEN_MAX  = 512;  // Up from 256
localparam integer VERSAL_BICKY_FEAT_MAX    = 128;  // Up from 64
localparam integer VERSAL_BICKY_OUT_MAX     = 64;   // Up from 16

// Embedding projector
localparam integer VERSAL_EMBED_DIM_IN      = 256;  // Input embedding dimension
localparam integer VERSAL_EMBED_DIM_OUT     = 128;  // Output (matches RC feat)

// ============================================================================
// Stream Type IDs (extends hub_config.svh values)
// ============================================================================

// Inherited from Zybo (backward-compatible)
localparam [7:0] VERSAL_TYPE_ADC            = 8'h02;
localparam [7:0] VERSAL_TYPE_RC             = 8'h03;
localparam [7:0] VERSAL_TYPE_BICKY          = 8'h04;

// New reasoning fabric types
localparam [7:0] VERSAL_TYPE_EMBED          = 8'h08;  // Embedding projector output
localparam [7:0] VERSAL_TYPE_AGENT          = 8'h09;  // Agent reasoning state
localparam [7:0] VERSAL_TYPE_CROSSBAR       = 8'h0A;  // Inter-lane message

// Lab instrument types
localparam [7:0] VERSAL_TYPE_OSCOPE         = 8'h10;
localparam [7:0] VERSAL_TYPE_SPECTRUM       = 8'h11;
localparam [7:0] VERSAL_TYPE_LOGIC_ANA      = 8'h12;
localparam [7:0] VERSAL_TYPE_VNA            = 8'h13;
localparam [7:0] VERSAL_TYPE_THERMAL        = 8'h14;
localparam [7:0] VERSAL_TYPE_POWER          = 8'h15;
localparam [7:0] VERSAL_TYPE_PROBE          = 8'h16;
localparam [7:0] VERSAL_TYPE_ENVIRON        = 8'h17;

// ============================================================================
// Safety Parameters
// ============================================================================

// Global watchdog timeout (PL clock cycles)
// At 250 MHz: 24-bit counter overflows at ~67 ms
localparam integer VERSAL_WDOG_BITS         = 24;

// Per-lane tick budget default (PL clock cycles for one inference)
localparam integer VERSAL_TICK_BUDGET       = 32'd131072;  // ~0.5 ms @ 250 MHz

// Duty cycle limiter
localparam integer VERSAL_PWM_PERIOD        = 16'd2499;  // ~100 kHz @ 250 MHz

// ============================================================================
// Stream Router Configuration
// ============================================================================

localparam integer VERSAL_PRIO_W            = 8;    // Priority field width
localparam integer VERSAL_TYPE_W            = 8;    // Type tag width

// ============================================================================
// NoC / Memory
// ============================================================================

// DDR4 base address for weight storage (PS-managed)
localparam [39:0] VERSAL_DDR_WEIGHT_BASE    = 40'h0_8000_0000;

// Per-lane weight region size (must accommodate RC + Bicky matrices)
// RC:    512 * 128 * 2 bytes = 128 KB (W_in)
// Bicky: 512 * 128 * 2 + 64 * 512 * 2 = 128 KB + 64 KB = 192 KB
// Total per lane: ~320 KB, round up to 512 KB
localparam integer VERSAL_WEIGHT_REGION_KB  = 512;

`endif
