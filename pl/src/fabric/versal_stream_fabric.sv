// versal_stream_fabric.sv
// N-lane generalization of hub_stream_fabric.sv for the Versal reasoning fabric.
//
// Combines VERSAL_NUM_LANES reasoning lane outputs + VERSAL_NUM_INSTRUMENTS
// instrument inputs + 1 host DMA ingress into a single prioritized output
// stream to the PS DMA egress path.
//
// Priority scheme (lower = higher priority):
//   0: Safety/instrument (highest — lab equipment must not drop frames)
//   1-N: Reasoning lanes (round-robin within same priority)
//   N+1: Host DMA ingress (lowest — host-originated data yields to fabric)
//
// Uses the existing stream_router IP which is already parameterized for
// arbitrary NUM_INPUTS. The type tag insertion allows PS software to
// demultiplex the output stream by source type.

`include "versal_config.svh"

module versal_stream_fabric #(
    parameter int DATA_W      = VERSAL_AXIS_W,
    parameter int NUM_LANES   = VERSAL_NUM_LANES,
    parameter int NUM_INSTR   = VERSAL_NUM_INSTRUMENTS,
    parameter int PRIO_W      = VERSAL_PRIO_W,
    parameter int TYPE_W      = VERSAL_TYPE_W
)(
    input  logic clk,
    input  logic rst,

    // Configuration
    input  logic insert_type_tag,

    // Lane inputs (from lane_tile plugin interfaces)
    input  logic [NUM_LANES*DATA_W-1:0]   lane_tdata,
    input  logic [NUM_LANES-1:0]          lane_tvalid,
    output logic [NUM_LANES-1:0]          lane_tready,
    input  logic [NUM_LANES-1:0]          lane_tlast,
    input  logic [NUM_LANES*TYPE_W-1:0]   lane_type_id,

    // Instrument inputs
    input  logic [NUM_INSTR*DATA_W-1:0]   instr_tdata,
    input  logic [NUM_INSTR-1:0]          instr_tvalid,
    output logic [NUM_INSTR-1:0]          instr_tready,
    input  logic [NUM_INSTR-1:0]          instr_tlast,
    input  logic [NUM_INSTR*TYPE_W-1:0]   instr_type_id,

    // Host DMA ingress (PS -> PL, lowest priority)
    input  logic [DATA_W-1:0]             host_tdata,
    input  logic                          host_tvalid,
    output logic                          host_tready,
    input  logic                          host_tlast,
    input  logic [TYPE_W-1:0]             host_type_id,

    // Arbitrated output to DMA egress
    output logic [DATA_W-1:0]             m_tdata,
    output logic                          m_tvalid,
    input  logic                          m_tready,
    output logic                          m_tlast,

    // Debug
    output logic [$clog2(NUM_LANES+NUM_INSTR+1)-1:0] active_slot
);
    localparam int TOTAL = NUM_LANES + NUM_INSTR + 1;
    localparam int SEL_W = (TOTAL > 1) ? $clog2(TOTAL) : 1;

    // Pack all inputs into the flat vectors expected by stream_router
    logic [TOTAL-1:0]          slot_enable;
    logic [TOTAL*PRIO_W-1:0]   slot_priority;
    logic [TOTAL*TYPE_W-1:0]   slot_type_id;
    logic [TOTAL*DATA_W-1:0]   s_tdata;
    logic [TOTAL-1:0]          s_tvalid;
    logic [TOTAL-1:0]          s_tready;
    logic [TOTAL-1:0]          s_tlast;

    // All slots enabled
    assign slot_enable = {TOTAL{1'b1}};

    // Assemble flat vectors
    genvar i;
    generate
        // Instrument inputs: slots [0 .. NUM_INSTR-1], priority 0 (highest)
        for (i = 0; i < NUM_INSTR; i++) begin : instr_pack
            assign s_tdata[i*DATA_W +: DATA_W]     = instr_tdata[i*DATA_W +: DATA_W];
            assign s_tvalid[i]                      = instr_tvalid[i];
            assign s_tlast[i]                       = instr_tlast[i];
            assign instr_tready[i]                  = s_tready[i];
            assign slot_priority[i*PRIO_W +: PRIO_W]= PRIO_W'(0);
            assign slot_type_id[i*TYPE_W +: TYPE_W] = instr_type_id[i*TYPE_W +: TYPE_W];
        end

        // Lane inputs: slots [NUM_INSTR .. NUM_INSTR+NUM_LANES-1], priority 1
        for (i = 0; i < NUM_LANES; i++) begin : lane_pack
            localparam int idx = NUM_INSTR + i;
            assign s_tdata[idx*DATA_W +: DATA_W]      = lane_tdata[i*DATA_W +: DATA_W];
            assign s_tvalid[idx]                       = lane_tvalid[i];
            assign s_tlast[idx]                        = lane_tlast[i];
            assign lane_tready[i]                      = s_tready[idx];
            assign slot_priority[idx*PRIO_W +: PRIO_W] = PRIO_W'(1);
            assign slot_type_id[idx*TYPE_W +: TYPE_W]  = lane_type_id[i*TYPE_W +: TYPE_W];
        end

        // Host DMA ingress: slot [TOTAL-1], priority 2 (lowest)
        localparam int host_idx = TOTAL - 1;
    endgenerate

    assign s_tdata[host_idx*DATA_W +: DATA_W]      = host_tdata;
    assign s_tvalid[host_idx]                       = host_tvalid;
    assign s_tlast[host_idx]                        = host_tlast;
    assign host_tready                              = s_tready[host_idx];
    assign slot_priority[host_idx*PRIO_W +: PRIO_W] = PRIO_W'(2);
    assign slot_type_id[host_idx*TYPE_W +: TYPE_W]  = host_type_id;

    // Instantiate the parameterized stream router
    logic [SEL_W-1:0] active_slot_int;

    stream_router #(
        .DATA_W(DATA_W),
        .NUM_INPUTS(TOTAL),
        .PRIO_W(PRIO_W),
        .TYPE_W(TYPE_W)
    ) u_router (
        .clk(clk),
        .rst(rst),
        .insert_type_tag(insert_type_tag),
        .slot_enable(slot_enable),
        .slot_priority(slot_priority),
        .slot_type_id(slot_type_id),
        .s_tdata(s_tdata),
        .s_tvalid(s_tvalid),
        .s_tready(s_tready),
        .s_tlast(s_tlast),
        .m_tdata(m_tdata),
        .m_tvalid(m_tvalid),
        .m_tready(m_tready),
        .m_tlast(m_tlast),
        .active_slot(active_slot_int)
    );

    assign active_slot = active_slot_int;

endmodule
