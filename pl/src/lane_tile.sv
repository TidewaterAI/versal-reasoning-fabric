// lane_tile.sv — Single reasoning lane for the Versal parallel fabric.
//
// Each lane_tile wraps:
//   1. A modality_plugin_if for standardized fabric integration
//   2. An AXI-Stream input path (features from DMA, instrument, or crossbar)
//   3. Compute dispatch (PL-local rc_core/bicky OR AIE offload via PLIO)
//   4. Per-lane safety kernel (CBF constraint enforcement)
//   5. AXI-Stream output to the global stream fabric
//
// In Phase 1 (PL-only), the compute is done by instantiating rc_core and
// bicky_inference directly. In Phase 3 (AIE offload), the compute path
// switches to aie_stream_adapter which forwards to/from AIE PLIOs.
//
// The lane_tile exposes a modality_plugin_if to the fabric so the outer
// versal_top sees a uniform interface regardless of internal compute mode.

`include "versal_config.svh"

module lane_tile #(
    parameter int LANE_ID       = 0,
    parameter int DATAW         = VERSAL_AXIS_W,
    parameter int QW            = VERSAL_QW,
    parameter int RC_NODES_MAX  = VERSAL_RC_NODES_MAX,
    parameter int RC_FEAT_MAX   = VERSAL_RC_FEAT_MAX,
    parameter int BICKY_HIDDEN  = VERSAL_BICKY_HIDDEN_MAX,
    parameter int BICKY_FEAT    = VERSAL_BICKY_FEAT_MAX,
    parameter int BICKY_OUT     = VERSAL_BICKY_OUT_MAX,
    parameter bit USE_AIE       = 0  // 0 = PL compute, 1 = AIE offload
)(
    input  logic                clk,
    input  logic                rst_n,

    // ---- Fabric-side plugin interface ----
    modality_plugin_if.plugin   plugin_if,

    // ---- Feature input (AXI-Stream from fabric ingress) ----
    input  logic [DATAW-1:0]    s_axis_tdata,
    input  logic                s_axis_tvalid,
    output logic                s_axis_tready,
    input  logic                s_axis_tlast,

    // ---- AIE PLIO ports (active only when USE_AIE=1) ----
    // To AIE: feature vectors for compute
    output logic [DATAW-1:0]    aie_tx_tdata,
    output logic                aie_tx_tvalid,
    input  logic                aie_tx_tready,
    output logic                aie_tx_tlast,
    // From AIE: compute results
    input  logic [DATAW-1:0]    aie_rx_tdata,
    input  logic                aie_rx_tvalid,
    output logic                aie_rx_tready,
    input  logic                aie_rx_tlast,

    // ---- Lane configuration (from CSR bank) ----
    input  logic                lane_enable,
    input  logic                mode_bicky,   // 0=RC, 1=Bicky
    input  logic [15:0]         rc_nodes_n,
    input  logic [15:0]         rc_feat_k,
    input  logic [15:0]         rc_alpha_q15,
    input  logic [15:0]         rc_rho_q15,
    input  logic [31:0]         tick_budget,

    // ---- Per-lane safety ----
    input  logic                global_kill,
    output logic                lane_fault
);

    // ========================================================================
    // Internal signals
    // ========================================================================

    // Compute input/output (muxed between PL-local and AIE paths)
    logic [DATAW-1:0]   compute_in_tdata;
    logic               compute_in_tvalid;
    logic               compute_in_tready;
    logic               compute_in_tlast;

    logic [DATAW-1:0]   compute_out_tdata;
    logic               compute_out_tvalid;
    logic               compute_out_tready;
    logic               compute_out_tlast;

    // Per-lane safety kernel signals
    logic               safety_intervention;
    logic               compute_fault;
    logic               rc_valid_tick;

    // ========================================================================
    // Input path: route features to compute
    // ========================================================================

    assign compute_in_tdata  = s_axis_tdata;
    assign compute_in_tvalid = s_axis_tvalid & lane_enable & ~global_kill;
    assign s_axis_tready     = compute_in_tready & lane_enable & ~global_kill;
    assign compute_in_tlast  = s_axis_tlast;

    // ========================================================================
    // Compute path selection
    // ========================================================================

    generate
        if (USE_AIE) begin : aie_path
            // Forward to AIE PLIO
            assign aie_tx_tdata    = compute_in_tdata;
            assign aie_tx_tvalid   = compute_in_tvalid;
            assign compute_in_tready = aie_tx_tready;
            assign aie_tx_tlast    = compute_in_tlast;

            // Receive from AIE PLIO
            assign compute_out_tdata  = aie_rx_tdata;
            assign compute_out_tvalid = aie_rx_tvalid;
            assign aie_rx_tready      = compute_out_tready;
            assign compute_out_tlast  = aie_rx_tlast;

            assign compute_fault   = 1'b0;  // AIE faults reported via separate path
            assign rc_valid_tick   = compute_out_tvalid & compute_out_tready & compute_out_tlast;

        end else begin : pl_path
            // PL-local compute: instantiate rc_core and bicky_inference
            // Mode mux selects which engine receives data

            logic [DATAW-1:0]   rc_out_tdata, bicky_out_tdata;
            logic               rc_out_tvalid, bicky_out_tvalid;
            logic               rc_out_tready, bicky_out_tready;
            logic               rc_out_tlast, bicky_out_tlast;
            logic               rc_fault_w, bicky_fault_w;
            logic               rc_valid_tick_w, bicky_valid_tick_w;

            // Tie off unused AIE ports
            assign aie_tx_tdata  = '0;
            assign aie_tx_tvalid = 1'b0;
            assign aie_tx_tlast  = 1'b0;
            assign aie_rx_tready = 1'b0;

            // RC Core
            rc_core #(
                .DATAW(DATAW),
                .QW(QW),
                .NODES_MAX(RC_NODES_MAX),
                .FEAT_MAX(RC_FEAT_MAX)
            ) u_rc (
                .clk(clk),
                .rst_n(rst_n),
                .s_axis_tdata(compute_in_tdata),
                .s_axis_tvalid(compute_in_tvalid & ~mode_bicky),
                .s_axis_tready(rc_s_ready),
                .s_axis_tlast(compute_in_tlast),
                .m_axis_tdata(rc_out_tdata),
                .m_axis_tvalid(rc_out_tvalid),
                .m_axis_tready(rc_out_tready),
                .m_axis_tlast(rc_out_tlast),
                .alpha_q15(rc_alpha_q15),
                .rho_q15(rc_rho_q15),
                .nodes_n(rc_nodes_n),
                .lanes_p(16'd1),
                .feat_k_in(rc_feat_k),
                .tick_budget(tick_budget),
                .seed_value(64'hDEAD_BEEF_0000_0000 | LANE_ID),
                .soft_reset(~lane_enable),
                .en(lane_enable & ~mode_bicky),
                .win_we(plugin_if.csr_we & (plugin_if.csr_addr[15:12] == 4'h1)),
                .win_addr(plugin_if.csr_wdata),
                .win_value(plugin_if.csr_wdata[15:0]),
                .wres_we(plugin_if.csr_we & (plugin_if.csr_addr[15:12] == 4'h2)),
                .wres_node(plugin_if.csr_addr[11:0]),
                .wres_slot(plugin_if.csr_addr[13:12]),
                .wres_col(plugin_if.csr_wdata[31:16]),
                .wres_value(plugin_if.csr_wdata[15:0]),
                .valid_tick(rc_valid_tick_w),
                .rc_fault(rc_fault_w)
            );

            // Bicky Inference
            bicky_inference #(
                .DATAW(DATAW),
                .QW(QW),
                .NODES_MAX(BICKY_HIDDEN),
                .FEAT_MAX(BICKY_FEAT),
                .OUT_MAX(BICKY_OUT)
            ) u_bicky (
                .clk(clk),
                .rst_n(rst_n),
                .s_axis_tdata(compute_in_tdata),
                .s_axis_tvalid(compute_in_tvalid & mode_bicky),
                .s_axis_tready(bicky_s_ready),
                .s_axis_tlast(compute_in_tlast),
                .m_axis_tdata(bicky_out_tdata),
                .m_axis_tvalid(bicky_out_tvalid),
                .m_axis_tready(bicky_out_tready),
                .m_axis_tlast(bicky_out_tlast),
                .nodes_n(rc_nodes_n),
                .feat_k_in(rc_feat_k),
                .out_k_in(BICKY_OUT[15:0]),
                .tick_budget(tick_budget),
                .en(lane_enable & mode_bicky),
                .win_we(plugin_if.csr_we & (plugin_if.csr_addr[15:12] == 4'h3)),
                .win_addr(plugin_if.csr_wdata),
                .win_value(plugin_if.csr_wdata[15:0]),
                .vout_we(plugin_if.csr_we & (plugin_if.csr_addr[15:12] == 4'h4)),
                .vout_addr(plugin_if.csr_wdata),
                .vout_value(plugin_if.csr_wdata[15:0]),
                .valid_tick(bicky_valid_tick_w),
                .fault(bicky_fault_w)
            );

            // Input ready mux
            logic rc_s_ready, bicky_s_ready;
            assign compute_in_tready = mode_bicky ? bicky_s_ready : rc_s_ready;

            // Output mux
            assign compute_out_tdata  = mode_bicky ? bicky_out_tdata  : rc_out_tdata;
            assign compute_out_tvalid = mode_bicky ? bicky_out_tvalid : rc_out_tvalid;
            assign compute_out_tlast  = mode_bicky ? bicky_out_tlast  : rc_out_tlast;
            assign rc_out_tready      = ~mode_bicky & compute_out_tready;
            assign bicky_out_tready   = mode_bicky  & compute_out_tready;

            assign compute_fault   = rc_fault_w | bicky_fault_w;
            assign rc_valid_tick   = rc_valid_tick_w | bicky_valid_tick_w;
        end
    endgenerate

    // ========================================================================
    // Per-lane safety kernel
    // ========================================================================

    safety_kernel #(.DATAW(32)) u_lane_safety (
        .clk(clk),
        .rst_n(rst_n & ~global_kill),
        .max_velocity(32'h7FFF_FFFF),      // Default: no velocity limit
        .max_acceleration(32'h7FFF_FFFF),
        .geofence_min_x(32'h8000_0000),    // Full range
        .geofence_max_x(32'h7FFF_FFFF),
        .candidate_velocity(compute_out_tdata[31:0]),
        .current_position_x(32'd0),
        .candidate_valid(compute_out_tvalid & compute_out_tlast),
        .safe_velocity(/* unused for classification lanes */),
        .safe_valid(),
        .intervention_active(safety_intervention),
        .violation_count()
    );

    // ========================================================================
    // Output to plugin interface
    // ========================================================================

    assign plugin_if.m_axis_tdata   = compute_out_tdata;
    assign plugin_if.m_axis_tvalid  = compute_out_tvalid & ~global_kill;
    assign plugin_if.m_axis_tlast   = compute_out_tlast;
    assign plugin_if.m_axis_type_id = mode_bicky ? VERSAL_TYPE_BICKY : VERSAL_TYPE_RC;
    assign compute_out_tready       = plugin_if.m_axis_tready;

    assign plugin_if.fault          = compute_fault | global_kill | safety_intervention;
    assign plugin_if.active         = lane_enable & ~global_kill;

    assign lane_fault               = compute_fault | safety_intervention;

    // CSR readback (stub — extend for status registers)
    assign plugin_if.csr_rdata      = 32'd0;
    assign plugin_if.csr_ready      = 1'b1;

endmodule
