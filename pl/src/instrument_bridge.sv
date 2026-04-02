// instrument_bridge.sv — Generic lab instrument ingress for the Versal fabric.
//
// Receives high-speed data from lab instruments (oscilloscopes, spectrum
// analyzers, VNAs, etc.) via AXI-Stream and packages it into the standard
// modality_plugin_if format for the reasoning fabric.
//
// Each instrument bridge instance handles one physical instrument channel.
// The bridge:
//   1. Accepts raw AXI-Stream data (width-converted if needed)
//   2. Prepends a timestamp header (same format as ad7124_reader)
//   3. Assigns a configurable stream type ID
//   4. Reports instrument status via the plugin interface
//
// The actual protocol conversion (SCPI/LXI/VISA -> AXI-Stream) happens
// upstream in PS software or in a dedicated protocol IP. This module is
// the PL-side framing and fabric integration point.

`include "versal_config.svh"

module instrument_bridge #(
    parameter int DATAW       = VERSAL_AXIS_W,
    parameter int INSTR_ID    = 0,
    parameter [7:0] TYPE_ID   = VERSAL_TYPE_OSCOPE
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // Plugin interface to fabric
    modality_plugin_if.plugin     plugin_if,

    // Raw instrument data input (AXI-Stream)
    input  logic [DATAW-1:0]      s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,

    // Configuration
    input  logic                  enable,
    input  logic [7:0]            type_id_override  // 0 = use parameter default
);

    // ========================================================================
    // State machine: header insertion + data passthrough
    // ========================================================================

    typedef enum logic [1:0] {
        ST_IDLE    = 2'd0,
        ST_HDR0    = 2'd1,
        ST_HDR1    = 2'd2,
        ST_DATA    = 2'd3
    } state_e;

    state_e state;
    logic [15:0] sample_count;
    logic [7:0]  effective_type;

    assign effective_type = (type_id_override != 8'h00) ? type_id_override : TYPE_ID;

    // Header format (matches ad7124_reader for cross-instrument compatibility):
    // HDR0: [seconds[47:0], ticks[15:0]]
    // HDR1: [instr_id[15:0], type_id[7:0], reserved[7:0], sample_count[15:0], frame_id[15:0]]

    wire [DATAW-1:0] header0 = {
        plugin_if.timestamp_seconds[47:0],
        plugin_if.timestamp_ticks[15:0]
    };

    reg [15:0] frame_id;

    wire [DATAW-1:0] header1 = {
        INSTR_ID[15:0],
        effective_type,
        8'd0,
        16'd0,          // sample_count (filled at TLAST, or 0 for streaming)
        frame_id
    };

    // Accept input only in DATA state when enabled
    assign s_axis_tready = (state == ST_DATA) && enable && !plugin_if.fault;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            sample_count     <= 16'd0;
            frame_id         <= 16'd0;
            plugin_if.m_axis_tdata  <= '0;
            plugin_if.m_axis_tvalid <= 1'b0;
            plugin_if.m_axis_tlast  <= 1'b0;
        end else begin
            plugin_if.m_axis_tvalid <= 1'b0;
            plugin_if.m_axis_tlast  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    sample_count <= 16'd0;
                    if (s_axis_tvalid && enable) begin
                        state <= ST_HDR0;
                    end
                end

                ST_HDR0: begin
                    plugin_if.m_axis_tdata  <= header0;
                    plugin_if.m_axis_tvalid <= 1'b1;
                    plugin_if.m_axis_tlast  <= 1'b0;
                    if (plugin_if.m_axis_tready) begin
                        state <= ST_HDR1;
                    end
                end

                ST_HDR1: begin
                    plugin_if.m_axis_tdata  <= header1;
                    plugin_if.m_axis_tvalid <= 1'b1;
                    plugin_if.m_axis_tlast  <= 1'b0;
                    if (plugin_if.m_axis_tready) begin
                        state <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        plugin_if.m_axis_tdata  <= s_axis_tdata;
                        plugin_if.m_axis_tvalid <= 1'b1;
                        plugin_if.m_axis_tlast  <= s_axis_tlast;
                        sample_count <= sample_count + 1'b1;

                        if (s_axis_tlast) begin
                            frame_id <= frame_id + 1'b1;
                            state    <= ST_IDLE;
                        end
                    end
                end
            endcase
        end
    end

    // ========================================================================
    // Plugin status
    // ========================================================================

    assign plugin_if.m_axis_type_id = effective_type;
    assign plugin_if.fault          = 1'b0;  // Instrument faults detected by PS
    assign plugin_if.active         = enable & (state != ST_IDLE);

    // CSR stub
    assign plugin_if.csr_rdata      = {16'd0, sample_count};
    assign plugin_if.csr_ready      = 1'b1;

endmodule
