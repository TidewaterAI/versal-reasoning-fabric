// bicky_inference.sv - Feedforward Neural Core for Active Control
// Derived from rc_core.sv.
// Implements:
//   1. Hidden Layer: a = tanh(Win * u + theta)
//   2. Output Layer: z = V * a + beta
//
// This module is designed for "Bicky" constructive neural networks where weights
// are learned offline and loaded for real-time inference.

module bicky_inference #(
    parameter int DATAW      = 64,
    parameter int QW         = 16,
    parameter int NODES_MAX  = 256,
    parameter int FEAT_MAX   = 64,
    parameter int OUT_MAX    = 16 // Max output dimension
)(
    input  logic                  clk,
    input  logic                  rst_n,
    // AXI-Stream Input (Features)
    input  logic [DATAW-1:0]      s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,
    // AXI-Stream Output (Class/Control)
    output logic [DATAW-1:0]      m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast,
    // Config
    input  logic [15:0]           nodes_n,
    input  logic [15:0]           feat_k_in,
    input  logic [15:0]           out_k_in, // Output dimension
    input  logic [31:0]           tick_budget,
    input  logic                  en,
    // Weight load interface
    input  logic                  win_we,
    input  logic [31:0]           win_addr,
    input  logic signed [15:0]    win_value,
    input  logic                  vout_we, // Output weights (V)
    input  logic [31:0]           vout_addr,
    input  logic signed [15:0]    vout_value,
    // Status
    output logic                  valid_tick,
    output logic                  fault
);
    localparam int Q1                = 1 << (QW - 1);
    localparam int TANH_TABLE_SIZE   = 64;
    localparam int FEAT_ADDR_W       = $clog2(FEAT_MAX);

    typedef enum logic [2:0] {
        ST_IDLE          = 3'd0,
        ST_CAPTURE       = 3'd1,
        ST_CAPTURE_WRITE = 3'd2,
        ST_HIDDEN        = 3'd3, // Compute a = tanh(Win*u)
        ST_OUTPUT_LAYER  = 3'd4, // Compute z = V*a
        ST_OUTPUT_STREAM = 3'd5
    } state_e;

    // Pipelined Config Registers (Timing Fix)
    reg [15:0] nodes_n_reg;
    reg [15:0] feat_k_reg;
    reg [15:0] out_k_reg;
    reg [31:0] tick_budget_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            nodes_n_reg     <= 16'd0;
            feat_k_reg      <= 16'd0;
            out_k_reg       <= 16'd0;
            tick_budget_reg <= 32'd0;
        end else if (en) begin
            // Hold values while enabled to prevent glitches if inputs wiggle
            // (Though inputs are expected static during en=1)
            nodes_n_reg     <= nodes_n_reg;
            feat_k_reg      <= feat_k_reg;
            out_k_reg       <= out_k_reg;
            tick_budget_reg <= tick_budget_reg;
        end else begin
            // Capture new config when disabled
            nodes_n_reg     <= nodes_n;
            feat_k_reg      <= feat_k_in;
            out_k_reg       <= out_k_in;
            tick_budget_reg <= tick_budget;
        end
    end

    // Clamp configuration (uses registered values) - registered to shorten timing paths
    reg [15:0] nodes_cfg;
    reg [15:0] feat_cfg;
    reg [15:0] out_cfg;
    reg [31:0] tick_budget_cfg;
    // Local buffers to reduce fanout
    reg [15:0] nodes_cfg_buf;
    reg [15:0] feat_cfg_buf;
    reg [15:0] out_cfg_buf;
    wire [FEAT_ADDR_W:0] feat_cfg_narrow = feat_cfg_buf[FEAT_ADDR_W:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            nodes_cfg       <= 16'd1;
            feat_cfg        <= 16'd1;
            out_cfg         <= 16'd1;
            tick_budget_cfg <= 32'd1024;
            nodes_cfg_buf   <= 16'd1;
            feat_cfg_buf    <= 16'd1;
            out_cfg_buf     <= 16'd1;
        end else if (!en) begin
            nodes_cfg       <= (nodes_n_reg == 16'd0) ? 16'd1 :
                               (nodes_n_reg > NODES_MAX) ? NODES_MAX[15:0] : nodes_n_reg;
            feat_cfg        <= (feat_k_reg == 16'd0) ? 16'd1 :
                               (feat_k_reg > FEAT_MAX) ? FEAT_MAX[15:0] : feat_k_reg;
            out_cfg         <= (out_k_reg == 16'd0) ? 16'd1 :
                               (out_k_reg > OUT_MAX) ? OUT_MAX[15:0] : out_k_reg;
            tick_budget_cfg <= (tick_budget_reg == 32'd0) ? 32'd1024 : tick_budget_reg;
            nodes_cfg_buf   <= (nodes_n_reg == 16'd0) ? 16'd1 :
                               (nodes_n_reg > NODES_MAX) ? NODES_MAX[15:0] : nodes_n_reg;
            feat_cfg_buf    <= (feat_k_reg == 16'd0) ? 16'd1 :
                               (feat_k_reg > FEAT_MAX) ? FEAT_MAX[15:0] : feat_k_reg;
            out_cfg_buf     <= (out_k_reg == 16'd0) ? 16'd1 :
                               (out_k_reg > OUT_MAX) ? OUT_MAX[15:0] : out_k_reg;
        end
    end

    // Memories
    reg signed [QW-1:0] feat_mem  [0:FEAT_MAX-1];
    reg signed [QW-1:0] hidden_mem [0:NODES_MAX-1]; // 'a' vector
    reg signed [QW-1:0] out_mem    [0:OUT_MAX-1];    // 'z' vector

    localparam int WIN_DEPTH  = NODES_MAX * FEAT_MAX;
    localparam int VOUT_DEPTH = OUT_MAX * NODES_MAX;

    localparam int FEAT_SHIFT = $clog2(FEAT_MAX);
    localparam int NODE_SHIFT = $clog2(NODES_MAX);

    reg signed [QW-1:0] win_mem  [0:WIN_DEPTH-1];
    reg signed [QW-1:0] vout_mem [0:VOUT_DEPTH-1];

    // Tanh LUT (Same as rc_core)
    logic signed [QW-1:0] tanh_lut [0:TANH_TABLE_SIZE-1];
    initial begin
        tanh_lut[ 0] = 16'sh0000; tanh_lut[ 1] = 16'sh0617; tanh_lut[ 2] = 16'sh0C27; tanh_lut[ 3] = 16'sh1229;
        tanh_lut[ 4] = 16'sh1817; tanh_lut[ 5] = 16'sh1DEA; tanh_lut[ 6] = 16'sh239B; tanh_lut[ 7] = 16'sh2927;
        tanh_lut[ 8] = 16'sh2E88; tanh_lut[ 9] = 16'sh33BA; tanh_lut[10] = 16'sh38BA; tanh_lut[11] = 16'sh3D85;
        tanh_lut[12] = 16'sh4219; tanh_lut[13] = 16'sh4675; tanh_lut[14] = 16'sh4A98; tanh_lut[15] = 16'sh4E82;
        tanh_lut[16] = 16'sh5233; tanh_lut[17] = 16'sh55AC; tanh_lut[18] = 16'sh58EE; tanh_lut[19] = 16'sh5BFB;
        tanh_lut[20] = 16'sh5ED4; tanh_lut[21] = 16'sh617B; tanh_lut[22] = 16'sh63F3; tanh_lut[23] = 16'sh663E;
        tanh_lut[24] = 16'sh685D; tanh_lut[25] = 16'sh6A54; tanh_lut[26] = 16'sh6C25; tanh_lut[27] = 16'sh6DD2;
        tanh_lut[28] = 16'sh6F5D; tanh_lut[29] = 16'sh70C9; tanh_lut[30] = 16'sh7218; tanh_lut[31] = 16'sh734B;
        tanh_lut[32] = 16'sh7465; tanh_lut[33] = 16'sh7568; tanh_lut[34] = 16'sh7655; tanh_lut[35] = 16'sh772E;
        tanh_lut[36] = 16'sh77F4; tanh_lut[37] = 16'sh78AA; tanh_lut[38] = 16'sh7950; tanh_lut[39] = 16'sh79E8;
        tanh_lut[40] = 16'sh7A72; tanh_lut[41] = 16'sh7AF1; tanh_lut[42] = 16'sh7B64; tanh_lut[43] = 16'sh7BCE;
        tanh_lut[44] = 16'sh7C2E; tanh_lut[45] = 16'sh7C85; tanh_lut[46] = 16'sh7CD5; tanh_lut[47] = 16'sh7D1E;
        tanh_lut[48] = 16'sh7D60; tanh_lut[49] = 16'sh7D9C; tanh_lut[50] = 16'sh7DD3; tanh_lut[51] = 16'sh7E06;
        tanh_lut[52] = 16'sh7E33; tanh_lut[53] = 16'sh7E5D; tanh_lut[54] = 16'sh7E82; tanh_lut[55] = 16'sh7EA5;
        tanh_lut[56] = 16'sh7EC4; tanh_lut[57] = 16'sh7EE1; tanh_lut[58] = 16'sh7EFB; tanh_lut[59] = 16'sh7F12;
        tanh_lut[60] = 16'sh7F28; tanh_lut[61] = 16'sh7F3B; tanh_lut[62] = 16'sh7F4D; tanh_lut[63] = 16'sh7F5D;
    end

    function automatic signed [15:0] tanh_lookup(input signed [31:0] val);
        logic signed [31:0] abs_val;
        logic [31:0]        scaled;
        logic [7:0]         idx;
        abs_val = (val < 0) ? -val : val;
        scaled = abs_val <<< 1; // multiply by 2
        idx = (scaled[31:15] >= (TANH_TABLE_SIZE-1)) ? (TANH_TABLE_SIZE-1) : scaled[20:15];
        return (val < 0) ? -tanh_lut[idx] : tanh_lut[idx];
    endfunction

    (* use_dsp = "yes" *)
    function automatic signed [31:0] mul_q15(input signed [15:0] a, input signed [15:0] b);
        mul_q15 = ({{16{a[15]}}, a} * {{16{b[15]}}, b});
    endfunction

    function automatic int win_index(input int node, input int feat);
        // FEAT_MAX is a power of two (64), so index is shift + add
        return (node <<< FEAT_SHIFT) + feat;
    endfunction

    function automatic int vout_index(input int out_dim, input int node);
        // NODES_MAX is a power of two (256), so index is shift + add
        return (out_dim <<< NODE_SHIFT) + node;
    endfunction

    state_e state;
    reg [FEAT_ADDR_W:0] feat_wr_addr;
    // ST_CAPTURE staging
    reg [63:0] feat_staging;
    reg        feat_stage_valid;
    reg [1:0]  feat_stage_lane;
    reg        feat_stage_last;
    reg [31:0] tick_counter;
    
    // Loop counters
    reg [15:0] node_idx;
    reg [15:0] feat_idx;
    reg [15:0] out_idx;
    reg [15:0] hidden_idx;
    reg signed [31:0] acc_work;
    reg signed [31:0] mul_stage;
    reg               mul_valid;
    reg signed [31:0] acc_pipe;
    reg signed [31:0] acc_pipe_buf;

    reg         fault_reg;
    reg         valid_tick_reg;
    reg         out_valid_reg;
    reg [DATAW-1:0] out_data_reg;
    reg         out_last_reg;

    assign s_axis_tready = (state == ST_IDLE || state == ST_CAPTURE) && en && !feat_stage_valid;
    assign m_axis_tdata  = out_data_reg;
    assign m_axis_tvalid = out_valid_reg;
    assign m_axis_tlast  = out_last_reg;
    assign fault         = fault_reg;
    assign valid_tick    = valid_tick_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            feat_wr_addr     <= {FEAT_ADDR_W+1{1'b0}};
            tick_counter     <= 32'd0;
            fault_reg        <= 1'b0;
            valid_tick_reg   <= 1'b0;
            out_valid_reg    <= 1'b0;
            out_last_reg     <= 1'b0;
            feat_stage_valid <= 1'b0;
            feat_stage_lane  <= 2'd0;
            feat_stage_last  <= 1'b0;
            out_data_reg     <= '0;
            node_idx         <= 16'd0;
            feat_idx         <= 16'd0;
            out_idx          <= 16'd0;
            hidden_idx       <= 16'd0;
            acc_work         <= 32'sd0;
            acc_pipe         <= 32'sd0;
            acc_pipe_buf     <= 32'sd0;
            mul_stage        <= 32'sd0;
            mul_valid        <= 1'b0;
        end else begin
            valid_tick_reg <= 1'b0;

            if (!en) begin
                state            <= ST_IDLE;
                feat_wr_addr     <= {FEAT_ADDR_W+1{1'b0}};
                tick_counter     <= 32'd0;
                fault_reg        <= 1'b0;
                out_valid_reg    <= 1'b0;
                out_last_reg     <= 1'b0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        feat_wr_addr     <= {FEAT_ADDR_W+1{1'b0}};
                        tick_counter     <= 32'd0;
                        fault_reg        <= 1'b0;
                        out_valid_reg    <= 1'b0;
                        out_last_reg     <= 1'b0;
                        if (s_axis_tvalid && s_axis_tready) begin
                            state <= ST_CAPTURE;
                        end
                    end

                    ST_CAPTURE: begin
                        if (s_axis_tvalid && s_axis_tready) begin
                            feat_staging     <= s_axis_tdata;
                            feat_stage_valid <= 1'b1;
                            feat_stage_lane  <= 2'd0;
                            feat_stage_last  <= s_axis_tlast;
                            state            <= ST_CAPTURE_WRITE;
                        end
                    end

                    ST_CAPTURE_WRITE: begin
                        if (feat_stage_valid) begin
                            if (feat_stage_lane < (DATAW/QW)) begin
                                if ((feat_wr_addr + feat_stage_lane) < feat_cfg_narrow) begin
                                    feat_mem[feat_wr_addr + feat_stage_lane] <= feat_staging[(feat_stage_lane*QW)+:QW];
                                end
                                feat_stage_lane <= feat_stage_lane + 1'b1;
                            end else begin
                                feat_wr_addr     <= feat_wr_addr + feat_stage_lane;
                                feat_stage_valid <= 1'b0;
                                if (feat_stage_last) begin
                                    state        <= ST_HIDDEN;
                                    node_idx     <= 16'd0;
                                    feat_idx     <= 16'd0;
                                    acc_work     <= 32'sd0;
                                    tick_counter <= 32'd0;
                                end else begin
                                    state <= ST_CAPTURE;
                                end
                            end
                        end else begin
                            state <= ST_CAPTURE;
                        end
                    end

                    ST_HIDDEN: begin // Compute a = tanh(Win * u)
                        automatic int win_addr_idx;
                        tick_counter <= tick_counter + 1;
                        if (tick_counter >= tick_budget_cfg) fault_reg <= 1'b1;

                        if (node_idx < nodes_cfg_buf) begin
                            if (feat_idx < feat_cfg_buf) begin
                                win_addr_idx = win_index(node_idx, feat_idx);
                                if (win_addr_idx < WIN_DEPTH) begin
                                    mul_stage <= mul_q15(win_mem[win_addr_idx], feat_mem[feat_idx]);
                                    mul_valid <= 1'b1;
                                end else begin
                                    mul_valid <= 1'b0;
                                end
                                feat_idx <= feat_idx + 1;
                                acc_pipe <= acc_work;
                                acc_pipe_buf <= acc_work;
                            end else begin
                                // Commit node
                                hidden_mem[node_idx] <= tanh_lookup(acc_work);
                                node_idx <= node_idx + 1;
                                feat_idx <= 16'd0;
                                acc_work <= 32'sd0;
                                mul_valid <= 1'b0;
                            end
                        end else begin
                            state      <= ST_OUTPUT_LAYER;
                            out_idx    <= 16'd0;
                            hidden_idx <= 16'd0;
                            acc_work   <= 32'sd0;
                            mul_valid  <= 1'b0;
                        end
                    end

                    ST_OUTPUT_LAYER: begin // Compute z = V * a
                        automatic int vout_addr_idx;
                        tick_counter <= tick_counter + 1;
                        if (tick_counter >= tick_budget_cfg) fault_reg <= 1'b1;

                        if (out_idx < out_cfg_buf) begin
                            if (hidden_idx < nodes_cfg_buf) begin
                                vout_addr_idx = vout_index(out_idx, hidden_idx);
                                if (vout_addr_idx < VOUT_DEPTH) begin
                                    mul_stage <= mul_q15(vout_mem[vout_addr_idx], hidden_mem[hidden_idx]);
                                    mul_valid <= 1'b1;
                                end
                                hidden_idx <= hidden_idx + 1;
                                acc_pipe <= acc_work;
                                acc_pipe_buf <= acc_work;
                            end else begin
                                // Commit output
                                // Saturate to Q1.15
                                if (acc_work > 32'sd32767) out_mem[out_idx] <= 16'sh7FFF;
                                else if (acc_work < -32'sd32768) out_mem[out_idx] <= -16'sh8000;
                                else out_mem[out_idx] <= acc_work[15:0];
                                
                                out_idx    <= out_idx + 1;
                                hidden_idx <= 16'd0;
                                acc_work   <= 32'sd0;
                                mul_valid  <= 1'b0;
                            end
                        end else begin
                            state   <= ST_OUTPUT_STREAM;
                            out_idx <= 16'd0;
                            mul_valid <= 1'b0;
                        end
                    end

                    ST_OUTPUT_STREAM: begin
                        if (m_axis_tready || !out_valid_reg) begin
                            if (out_idx < out_cfg) begin
                                // Pack 4x 16-bit values into 64-bit word
                                logic [63:0] pack_data;
                                pack_data = 64'd0;
                                for (int i=0; i<4; i++) begin
                                    if (out_idx + i < out_cfg) begin
                                        pack_data[i*16 +: 16] = out_mem[out_idx + i];
                                    end
                                end
                                out_data_reg  <= pack_data;
                                out_valid_reg <= 1'b1;
                                
                                if (out_idx + 4 >= out_cfg) begin
                                    out_last_reg <= 1'b1;
                                    state        <= ST_IDLE; // Done after this beat
                                end
                                out_idx <= out_idx + 4;
                            end
                        end
                    end
                endcase
            end

            // Accumulate pipeline (shared for hidden/output states)
            if (mul_valid) begin
                acc_work   <= acc_pipe_buf + (mul_stage >>> 15);
                mul_valid  <= 1'b0;
            end
        end
    end

    // Weight Writes
    always_ff @(posedge clk) begin
        if (win_we) begin
            automatic int node = win_addr[31:16];
            automatic int feat = win_addr[15:0];
            automatic int addr = win_index(node, feat);
            if (addr < WIN_DEPTH) win_mem[addr] <= win_value;
        end
        if (vout_we) begin
            automatic int out_d = vout_addr[31:16];
            automatic int node  = vout_addr[15:0];
            automatic int addr  = vout_index(out_d, node);
            if (addr < VOUT_DEPTH) vout_mem[addr] <= vout_value;
        end
    end

    endmodule
