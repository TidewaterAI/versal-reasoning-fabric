// modality_plugin_if.sv
// Standard plugin boundary for modality blocks during hub modularization.
// This interface intentionally stays small and composable:
//   - trigger/gate control from fabric
//   - one AXI-Stream egress from plugin
//   - optional lightweight CSR sideband
//   - timestamp metadata fan-in to plugin
//   - plugin status back to fabric

interface modality_plugin_if #(
    parameter int AXIS_W = 64,
    parameter int TS_SEC_W = 64,
    parameter int TS_TICK_W = 32,
    parameter int CSR_ADDR_W = 16,
    parameter int CSR_DATA_W = 32
) (
    input logic clk,
    input logic rst_n
);
    // Fabric -> plugin controls
    logic trig;
    logic gate;
    logic [TS_SEC_W-1:0] timestamp_seconds;
    logic [TS_TICK_W-1:0] timestamp_ticks;

    // Plugin -> fabric health/state
    logic fault;
    logic active;

    // Plugin -> fabric AXI-Stream output
    logic [AXIS_W-1:0] m_axis_tdata;
    logic m_axis_tvalid;
    logic m_axis_tready;
    logic m_axis_tlast;
    logic [7:0] m_axis_type_id;  // Self-identifies stream type for downstream demux

    // Optional CSR sideband
    logic csr_we;
    logic csr_re;
    logic [CSR_ADDR_W-1:0] csr_addr;
    logic [CSR_DATA_W-1:0] csr_wdata;
    logic [CSR_DATA_W-1:0] csr_rdata;
    logic csr_ready;

    modport fabric (
        input  clk,
        input  rst_n,
        input  fault,
        input  active,
        input  m_axis_tdata,
        input  m_axis_tvalid,
        input  m_axis_tlast,
        input  m_axis_type_id,
        input  csr_rdata,
        input  csr_ready,
        output trig,
        output gate,
        output timestamp_seconds,
        output timestamp_ticks,
        output m_axis_tready,
        output csr_we,
        output csr_re,
        output csr_addr,
        output csr_wdata
    );

    modport plugin (
        input  clk,
        input  rst_n,
        input  trig,
        input  gate,
        input  timestamp_seconds,
        input  timestamp_ticks,
        input  m_axis_tready,
        input  csr_we,
        input  csr_re,
        input  csr_addr,
        input  csr_wdata,
        output fault,
        output active,
        output m_axis_tdata,
        output m_axis_tvalid,
        output m_axis_tlast,
        output m_axis_type_id,
        output csr_rdata,
        output csr_ready
    );
endinterface
