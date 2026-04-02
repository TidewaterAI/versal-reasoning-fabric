// versal_top.sv — Top-level PL module for the Versal VCK190 reasoning fabric.
//
// Instantiates:
//   - N lane_tiles (parallel reasoning lanes with RC/Bicky compute)
//   - versal_stream_fabric (N:1 priority arbiter for all output streams)
//   - Global safety supervisor (watchdog, kill latch, duty accounting)
//   - Timestamp counter (PTP/PPS-locked, 64-bit seconds + 32-bit ticks)
//   - Instrument input ports (lab equipment streams)
//   - Crypto signer (frame provenance)
//
// The AIE graph is instantiated in the block design and connected via PLIO
// ports that pass through this module. When USE_AIE=0 (Phase 1), all compute
// is done in PL via the existing rc_core and bicky_inference modules.
//
// DMA paths (PS ↔ PL) are handled by the block design AXI infrastructure.
// This module exposes AXI-Stream ports that connect to DMA engines in the BD.

`include "versal_config.svh"

module versal_top #(
    parameter int NUM_LANES   = VERSAL_NUM_LANES,
    parameter int NUM_INSTR   = VERSAL_NUM_INSTRUMENTS,
    parameter int DATAW       = VERSAL_AXIS_W,
    parameter bit USE_AIE     = 0
)(
    // ---- Clocks and resets ----
    input  logic        clk_pl,          // PL fabric clock (250 MHz from CIPS)
    input  logic        rst_n,           // Active-low reset

    // ---- PPS / timestamp ----
    input  logic        pps_in,          // 1 PPS reference (optional)
    output logic [63:0] timestamp_seconds,
    output logic [31:0] timestamp_ticks,

    // ---- DMA ingress: PS -> PL (features/commands to lanes) ----
    input  logic [DATAW-1:0]  mm2s_tdata,
    input  logic              mm2s_tvalid,
    output logic              mm2s_tready,
    input  logic              mm2s_tlast,

    // ---- DMA egress: PL -> PS (results from fabric) ----
    output logic [DATAW-1:0]  s2mm_tdata,
    output logic              s2mm_tvalid,
    input  logic              s2mm_tready,
    output logic              s2mm_tlast,

    // ---- AIE PLIO ports (active when USE_AIE=1) ----
    // Per-lane TX (to AIE)
    output logic [NUM_LANES*DATAW-1:0]  aie_tx_tdata,
    output logic [NUM_LANES-1:0]        aie_tx_tvalid,
    input  logic [NUM_LANES-1:0]        aie_tx_tready,
    output logic [NUM_LANES-1:0]        aie_tx_tlast,
    // Per-lane RX (from AIE)
    input  logic [NUM_LANES*DATAW-1:0]  aie_rx_tdata,
    input  logic [NUM_LANES-1:0]        aie_rx_tvalid,
    output logic [NUM_LANES-1:0]        aie_rx_tready,
    input  logic [NUM_LANES-1:0]        aie_rx_tlast,

    // ---- Instrument inputs (FMC+ / QSFP28 / GPIO) ----
    input  logic [NUM_INSTR*DATAW-1:0]  instr_tdata,
    input  logic [NUM_INSTR-1:0]        instr_tvalid,
    output logic [NUM_INSTR-1:0]        instr_tready,
    input  logic [NUM_INSTR-1:0]        instr_tlast,

    // ---- External safety ----
    input  logic        kill_ext,        // External emergency stop
    output logic        fabric_fault,    // Aggregated fault indicator

    // ---- AXI-Lite CSR bus (from CIPS via interconnect) ----
    // Directly wired to lane CSR banks in block design.
    // Simplified here: per-lane config driven by PS software.
    input  logic [NUM_LANES-1:0]    lane_enable,
    input  logic [NUM_LANES-1:0]    lane_mode_bicky
);

    // ========================================================================
    // Reset and PPS synchronization
    // ========================================================================

    logic rst;
    assign rst = ~rst_n;

    logic pps_meta, pps_sync, pps_sync_d, pps_edge;
    always_ff @(posedge clk_pl) begin
        if (rst) begin
            pps_meta   <= 1'b0;
            pps_sync   <= 1'b0;
            pps_sync_d <= 1'b0;
        end else begin
            pps_meta   <= pps_in;
            pps_sync   <= pps_meta;
            pps_sync_d <= pps_sync;
        end
    end
    assign pps_edge = pps_sync & ~pps_sync_d;

    // ========================================================================
    // Timestamp counter
    // ========================================================================

    wire [63:0] ts_seconds;
    wire [31:0] ts_ticks;

    timestamp_counter #(
        .TICKS_PER_SEC(VERSAL_TS_TICKS_PER_SEC)
    ) u_timestamp (
        .clk(clk_pl),
        .rst(rst),
        .pps_sync(pps_edge),
        .seconds(ts_seconds),
        .ticks(ts_ticks)
    );

    assign timestamp_seconds = ts_seconds;
    assign timestamp_ticks   = ts_ticks;

    // ========================================================================
    // Global safety supervisor
    // ========================================================================

    logic global_kill_latched;
    logic [31:0] global_duty_count;
    logic any_lane_valid_tick;

    safety_supervisor u_global_safety (
        .clk(clk_pl),
        .rst(rst),
        .kill_ext(kill_ext),
        .limit_over(1'b0),
        .photodiode_over(1'b0),
        .mea_over(1'b0),
        .wdog_kick(any_lane_valid_tick),
        .duty_tick(|lane_enable),
        .duty_limit(32'd0),    // Disable duty limit (PS configures per-lane)
        .counters_clear(1'b0),
        .kill_latched(global_kill_latched),
        .duty_count(global_duty_count)
    );

    // ========================================================================
    // Lane tile instantiation
    // ========================================================================

    // Per-lane plugin interfaces
    modality_plugin_if #(.AXIS_W(DATAW)) lane_plugin_if [NUM_LANES-1:0] (
        .clk(clk_pl),
        .rst_n(rst_n)
    );

    // Aggregated lane outputs for stream fabric
    logic [NUM_LANES*DATAW-1:0]  lane_out_tdata;
    logic [NUM_LANES-1:0]        lane_out_tvalid;
    logic [NUM_LANES-1:0]        lane_out_tready;
    logic [NUM_LANES-1:0]        lane_out_tlast;
    logic [NUM_LANES*8-1:0]      lane_out_type_id;
    logic [NUM_LANES-1:0]        lane_fault_vec;

    // DMA ingress demux: for now, broadcast to all lanes (PS selects via enable)
    // TODO: Add a proper demux that routes by lane ID in the frame header

    genvar g;
    generate
        for (g = 0; g < NUM_LANES; g++) begin : lane_gen

            // Feed timestamp to plugin interface
            assign lane_plugin_if[g].trig              = 1'b0; // No trigger yet
            assign lane_plugin_if[g].gate              = lane_enable[g];
            assign lane_plugin_if[g].timestamp_seconds = ts_seconds;
            assign lane_plugin_if[g].timestamp_ticks   = ts_ticks;
            assign lane_plugin_if[g].csr_we            = 1'b0; // CSR driven by AXI-Lite
            assign lane_plugin_if[g].csr_re            = 1'b0;
            assign lane_plugin_if[g].csr_addr          = '0;
            assign lane_plugin_if[g].csr_wdata         = '0;

            lane_tile #(
                .LANE_ID(g),
                .DATAW(DATAW),
                .USE_AIE(USE_AIE)
            ) u_lane (
                .clk(clk_pl),
                .rst_n(rst_n),
                .plugin_if(lane_plugin_if[g]),

                // All lanes receive the same DMA ingress (broadcast)
                .s_axis_tdata(mm2s_tdata),
                .s_axis_tvalid(mm2s_tvalid & lane_enable[g]),
                .s_axis_tready(/* per-lane ready, OR'd below */),
                .s_axis_tlast(mm2s_tlast),

                // AIE PLIO ports
                .aie_tx_tdata(aie_tx_tdata[g*DATAW +: DATAW]),
                .aie_tx_tvalid(aie_tx_tvalid[g]),
                .aie_tx_tready(aie_tx_tready[g]),
                .aie_tx_tlast(aie_tx_tlast[g]),
                .aie_rx_tdata(aie_rx_tdata[g*DATAW +: DATAW]),
                .aie_rx_tvalid(aie_rx_tvalid[g]),
                .aie_rx_tready(aie_rx_tready[g]),
                .aie_rx_tlast(aie_rx_tlast[g]),

                // Configuration
                .lane_enable(lane_enable[g]),
                .mode_bicky(lane_mode_bicky[g]),
                .rc_nodes_n(16'd256),       // Default; PS overrides via CSR
                .rc_feat_k(16'd13),
                .rc_alpha_q15(16'sh2666),   // ~0.3 in Q1.15
                .rc_rho_q15(16'sh7333),     // ~0.9 in Q1.15
                .tick_budget(VERSAL_TICK_BUDGET),

                // Safety
                .global_kill(global_kill_latched),
                .lane_fault(lane_fault_vec[g])
            );

            // Collect lane plugin outputs for stream fabric
            assign lane_out_tdata[g*DATAW +: DATAW] = lane_plugin_if[g].m_axis_tdata;
            assign lane_out_tvalid[g]               = lane_plugin_if[g].m_axis_tvalid;
            assign lane_plugin_if[g].m_axis_tready  = lane_out_tready[g];
            assign lane_out_tlast[g]                = lane_plugin_if[g].m_axis_tlast;
            assign lane_out_type_id[g*8 +: 8]       = lane_plugin_if[g].m_axis_type_id;
        end
    endgenerate

    // DMA ingress ready: accept if any enabled lane accepts
    assign mm2s_tready = |(lane_enable);  // Simplified; proper demux in later phase

    // Watchdog kick: any lane producing valid output keeps the watchdog alive
    assign any_lane_valid_tick = |lane_out_tvalid;

    // ========================================================================
    // Instrument input type IDs (default assignment)
    // ========================================================================

    logic [NUM_INSTR*8-1:0] instr_type_ids;
    generate
        for (g = 0; g < NUM_INSTR; g++) begin : instr_type_gen
            assign instr_type_ids[g*8 +: 8] = VERSAL_TYPE_OSCOPE + g[7:0];
        end
    endgenerate

    // ========================================================================
    // Stream fabric: merge all outputs to DMA egress
    // ========================================================================

    logic [$clog2(NUM_LANES+NUM_INSTR+1)-1:0] fabric_active_slot;

    versal_stream_fabric #(
        .DATA_W(DATAW),
        .NUM_LANES(NUM_LANES),
        .NUM_INSTR(NUM_INSTR)
    ) u_stream_fabric (
        .clk(clk_pl),
        .rst(rst),
        .insert_type_tag(1'b1),  // Always insert type tags for PS demux

        .lane_tdata(lane_out_tdata),
        .lane_tvalid(lane_out_tvalid),
        .lane_tready(lane_out_tready),
        .lane_tlast(lane_out_tlast),
        .lane_type_id(lane_out_type_id),

        .instr_tdata(instr_tdata),
        .instr_tvalid(instr_tvalid),
        .instr_tready(instr_tready),
        .instr_tlast(instr_tlast),
        .instr_type_id(instr_type_ids),

        .host_tdata('0),
        .host_tvalid(1'b0),
        .host_tready(),
        .host_tlast(1'b0),
        .host_type_id(8'h00),

        .m_tdata(s2mm_tdata),
        .m_tvalid(s2mm_tvalid),
        .m_tready(s2mm_tready),
        .m_tlast(s2mm_tlast),

        .active_slot(fabric_active_slot)
    );

    // ========================================================================
    // Aggregated fault
    // ========================================================================

    assign fabric_fault = global_kill_latched | (|lane_fault_vec);

endmodule
