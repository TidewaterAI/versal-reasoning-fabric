// stream_router.sv
// N:1 AXI-Stream router with:
//   - priority-based arbitration
//   - optional one-beat type header insertion
//   - disabled-slot bypass at selection time
//   - frame-atomic forwarding once granted

module stream_router #(
    parameter int DATA_W = 64,
    parameter int NUM_INPUTS = 4,
    parameter int PRIO_W = 4,
    parameter int TYPE_W = 8
) (
    input  logic clk,
    input  logic rst,

    input  logic insert_type_tag,

    // Per-slot controls
    input  logic [NUM_INPUTS-1:0] slot_enable,
    input  logic [NUM_INPUTS*PRIO_W-1:0] slot_priority,
    input  logic [NUM_INPUTS*TYPE_W-1:0] slot_type_id,

    // Input stream lanes (flattened)
    input  logic [NUM_INPUTS*DATA_W-1:0] s_tdata,
    input  logic [NUM_INPUTS-1:0] s_tvalid,
    output logic [NUM_INPUTS-1:0] s_tready,
    input  logic [NUM_INPUTS-1:0] s_tlast,

    // Routed output stream
    output logic [DATA_W-1:0] m_tdata,
    output logic m_tvalid,
    input  logic m_tready,
    output logic m_tlast,

    // Debug/telemetry
    output logic [((NUM_INPUTS > 1) ? $clog2(NUM_INPUTS) : 1)-1:0] active_slot
);
    localparam int SEL_W = (NUM_INPUTS > 1) ? $clog2(NUM_INPUTS) : 1;

    typedef enum logic [1:0] {
        ST_IDLE = 2'd0,
        ST_TYPE = 2'd1,
        ST_DATA = 2'd2
    } state_t;

    state_t state;
    logic [SEL_W-1:0] sel;

    logic grant_valid;
    logic [SEL_W-1:0] grant_slot;
    logic [PRIO_W-1:0] grant_prio;

    function automatic logic [PRIO_W-1:0] lane_priority(input int idx);
        lane_priority = slot_priority[idx*PRIO_W +: PRIO_W];
    endfunction

    function automatic logic [TYPE_W-1:0] lane_type(input int idx);
        lane_type = slot_type_id[idx*TYPE_W +: TYPE_W];
    endfunction

    function automatic logic [DATA_W-1:0] lane_data(input int idx);
        lane_data = s_tdata[idx*DATA_W +: DATA_W];
    endfunction

    assign active_slot = sel;

    // Select enabled + valid input with lowest numeric priority.
    // Ties are broken by lower slot index (loop order).
    always_comb begin
        grant_valid = 1'b0;
        grant_slot = '0;
        grant_prio = {PRIO_W{1'b1}};

        for (int i = 0; i < NUM_INPUTS; i++) begin
            if (slot_enable[i] && s_tvalid[i]) begin
                if (!grant_valid || (lane_priority(i) < grant_prio)) begin
                    grant_valid = 1'b1;
                    grant_slot = i[SEL_W-1:0];
                    grant_prio = lane_priority(i);
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            sel <= '0;
            m_tdata <= '0;
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
            s_tready <= '0;
        end else begin
            m_tdata <= '0;
            m_tvalid <= 1'b0;
            m_tlast <= 1'b0;
            s_tready <= '0;

            case (state)
                ST_IDLE: begin
                    if (grant_valid) begin
                        sel <= grant_slot;
                        state <= insert_type_tag ? ST_TYPE : ST_DATA;
                    end
                end

                ST_TYPE: begin
                    m_tvalid <= 1'b1;
                    m_tdata <= {{(DATA_W-TYPE_W){1'b0}}, lane_type(sel)};
                    m_tlast <= 1'b0;
                    if (m_tready) begin
                        state <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    m_tvalid <= s_tvalid[sel];
                    m_tdata <= lane_data(sel);
                    m_tlast <= s_tlast[sel];
                    s_tready[sel] <= m_tready;

                    if (m_tvalid && m_tready && m_tlast) begin
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
