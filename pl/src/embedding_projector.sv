// embedding_projector.sv — Hardware matrix-vector multiply for dimensionality
// reduction. Converts high-dimensional input embeddings (token IDs, sensor
// readings, agent state vectors) into the fixed-dimension feature vectors
// expected by downstream RC and Bicky compute lanes.
//
// Architecture: y = W * x (no bias, optional ReLU/tanh activation)
//   - W is DIM_OUT x DIM_IN, stored in BRAM, loadable via CSR
//   - x is DIM_IN x 1, arriving as packed Q1.15 values on AXI-Stream
//   - y is DIM_OUT x 1, emitted as packed Q1.15 values on AXI-Stream
//
// This is structurally identical to the Bicky hidden layer computation
// but without the per-node activation (or with configurable activation).
// The same mul_q15 + accumulate pattern transfers directly from bicky_inference.sv.

`include "versal_config.svh"

module embedding_projector #(
    parameter int DATAW   = VERSAL_AXIS_W,
    parameter int QW      = VERSAL_QW,
    parameter int DIM_IN  = VERSAL_EMBED_DIM_IN,
    parameter int DIM_OUT = VERSAL_EMBED_DIM_OUT
)(
    input  logic                  clk,
    input  logic                  rst_n,

    // AXI-Stream input (embedding vector, packed QW per beat)
    input  logic [DATAW-1:0]      s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,

    // AXI-Stream output (projected features)
    output logic [DATAW-1:0]      m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast,

    // Projection matrix load (DIM_OUT x DIM_IN weights)
    input  logic                  proj_we,
    input  logic [31:0]           proj_addr,   // [31:16] = row, [15:0] = col
    input  logic signed [QW-1:0]  proj_value,

    // Control
    input  logic                  en,
    output logic                  fault
);
    // ========================================================================
    // Constants
    // ========================================================================

    localparam int WORDS_PER_BEAT = DATAW / QW;         // 4 for 64-bit / 16-bit
    localparam int W_DEPTH        = DIM_OUT * DIM_IN;
    localparam int IN_SHIFT       = $clog2(DIM_IN);

    // ========================================================================
    // Memories
    // ========================================================================

    reg signed [QW-1:0] input_mem  [0:DIM_IN-1];
    reg signed [QW-1:0] output_mem [0:DIM_OUT-1];
    reg signed [QW-1:0] weight_mem [0:W_DEPTH-1];

    // ========================================================================
    // State machine
    // ========================================================================

    typedef enum logic [2:0] {
        ST_IDLE     = 3'd0,
        ST_CAPTURE  = 3'd1,
        ST_COMPUTE  = 3'd2,
        ST_OUTPUT   = 3'd3
    } state_e;

    state_e state;
    reg [$clog2(DIM_IN):0]  in_wr_ptr;
    reg [$clog2(DIM_OUT):0] out_row;
    reg [$clog2(DIM_IN):0]  col_idx;
    reg signed [31:0]       acc;
    reg [31:0]              tick_counter;

    reg                     out_valid;
    reg [DATAW-1:0]         out_data;
    reg                     out_last;

    assign s_axis_tready = (state == ST_IDLE || state == ST_CAPTURE) && en;
    assign m_axis_tdata  = out_data;
    assign m_axis_tvalid = out_valid;
    assign m_axis_tlast  = out_last;

    // ========================================================================
    // Q1.15 multiply
    // ========================================================================

    function automatic signed [31:0] mul_q15(input signed [15:0] a, input signed [15:0] b);
        mul_q15 = ({{16{a[15]}}, a} * {{16{b[15]}}, b});
    endfunction

    function automatic signed [15:0] sat_q15(input signed [31:0] val);
        if (val > 32'sd32767)       sat_q15 = 16'sh7FFF;
        else if (val < -32'sd32768) sat_q15 = 16'sh8000;
        else                        sat_q15 = val[15:0];
    endfunction

    // ========================================================================
    // Main FSM
    // ========================================================================

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            in_wr_ptr    <= '0;
            out_row      <= '0;
            col_idx      <= '0;
            acc          <= 32'sd0;
            tick_counter <= 32'd0;
            out_valid    <= 1'b0;
            out_data     <= '0;
            out_last     <= 1'b0;
            fault        <= 1'b0;
        end else if (!en) begin
            state     <= ST_IDLE;
            out_valid <= 1'b0;
            fault     <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_last  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    in_wr_ptr    <= '0;
                    tick_counter <= 32'd0;
                    fault        <= 1'b0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Capture first beat
                        for (int i = 0; i < WORDS_PER_BEAT; i++) begin
                            if (i < DIM_IN)
                                input_mem[i] <= s_axis_tdata[i*QW +: QW];
                        end
                        in_wr_ptr <= WORDS_PER_BEAT;
                        state     <= s_axis_tlast ? ST_COMPUTE : ST_CAPTURE;
                    end
                end

                ST_CAPTURE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        for (int i = 0; i < WORDS_PER_BEAT; i++) begin
                            if ((in_wr_ptr + i) < DIM_IN)
                                input_mem[in_wr_ptr + i] <= s_axis_tdata[i*QW +: QW];
                        end
                        in_wr_ptr <= in_wr_ptr + WORDS_PER_BEAT;
                        if (s_axis_tlast) begin
                            state   <= ST_COMPUTE;
                            out_row <= '0;
                            col_idx <= '0;
                            acc     <= 32'sd0;
                        end
                    end
                end

                ST_COMPUTE: begin
                    tick_counter <= tick_counter + 1;
                    if (tick_counter >= VERSAL_TICK_BUDGET) fault <= 1'b1;

                    if (out_row < DIM_OUT) begin
                        if (col_idx < DIM_IN) begin
                            // MAC: acc += W[row][col] * input[col]
                            automatic int w_addr = (out_row << IN_SHIFT) + col_idx;
                            if (w_addr < W_DEPTH)
                                acc <= acc + (mul_q15(weight_mem[w_addr], input_mem[col_idx]) >>> 15);
                            col_idx <= col_idx + 1;
                        end else begin
                            // Row complete — store and advance
                            output_mem[out_row] <= sat_q15(acc);
                            out_row <= out_row + 1;
                            col_idx <= '0;
                            acc     <= 32'sd0;
                        end
                    end else begin
                        // All rows done — emit output
                        state   <= ST_OUTPUT;
                        out_row <= '0;
                    end
                end

                ST_OUTPUT: begin
                    if (m_axis_tready || !out_valid) begin
                        if (out_row < DIM_OUT) begin
                            // Pack WORDS_PER_BEAT outputs per beat
                            logic [DATAW-1:0] pack;
                            pack = '0;
                            for (int i = 0; i < WORDS_PER_BEAT; i++) begin
                                if ((out_row + i) < DIM_OUT)
                                    pack[i*QW +: QW] = output_mem[out_row + i];
                            end
                            out_data  <= pack;
                            out_valid <= 1'b1;
                            out_last  <= (out_row + WORDS_PER_BEAT >= DIM_OUT);
                            out_row   <= out_row + WORDS_PER_BEAT;
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end
            endcase
        end
    end

    // ========================================================================
    // Weight writes
    // ========================================================================

    always_ff @(posedge clk) begin
        if (proj_we) begin
            automatic int row  = proj_addr[31:16];
            automatic int col  = proj_addr[15:0];
            automatic int addr = (row << IN_SHIFT) + col;
            if (addr < W_DEPTH)
                weight_mem[addr] <= proj_value;
        end
    end

endmodule
