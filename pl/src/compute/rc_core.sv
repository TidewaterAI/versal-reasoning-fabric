// rc_core.sv — Pilot-friendly Q1.15 reservoir core with deterministic timing.
// Implements a simple leaky update driven by CSR-generated weights and a LUT
// tanh approximation. The design is intentionally conservative so it fits the
// Zybo Z7-20 fabric while providing the hooks called out in RC_PLANNING.md.

module rc_core #(
    parameter int DATAW      = 64,
    parameter int QW         = 16,
    parameter int NODES_MAX  = 256,
    parameter int LANES_MAX  = 8,
    parameter int FEAT_MAX   = 64
)(
    input  logic                  clk,
    input  logic                  rst_n,
    // AXI-Stream in/out
    input  logic [DATAW-1:0]      s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,
    output logic [DATAW-1:0]      m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast,
    // Config (from AXI-Lite register bank)
    input  logic [15:0]           alpha_q15,
    input  logic [15:0]           rho_q15,
    input  logic [15:0]           nodes_n,
    input  logic [15:0]           lanes_p,
    input  logic [15:0]           feat_k_in,
    input  logic [31:0]           tick_budget,
    input  logic [63:0]           seed_value,
    input  logic                  soft_reset,
    input  logic                  en,
    // Weight load interface
    input  logic                  win_we,
    input  logic [31:0]           win_addr,
    input  logic signed [15:0]    win_value,
    input  logic                  wres_we,
    input  logic [15:0]           wres_node,
    input  logic [1:0]            wres_slot,
    input  logic [15:0]           wres_col,
    input  logic signed [15:0]    wres_value,
    // Status
    output logic                  valid_tick,
    output logic                  rc_fault
);
    localparam int Q1                = 1 << (QW - 1);
    localparam int ST_IDLE           = 0;
    localparam int ST_CAPTURE        = 1;
    localparam int ST_UPDATE         = 2;
    localparam int ST_OUTPUT         = 3;
    localparam int WRES_SLOTS        = 8;  // B3 FIX: was 4, too few for Python dense Wres parity (128 nodes @ 10% sparsity ≈ 12.8 avg connections)
    localparam int TANH_TABLE_SIZE   = 64;

    // Clamp configuration into hardware limits.
    wire [15:0] nodes_cfg = (nodes_n == 16'd0) ? 16'd1 :
                            (nodes_n > NODES_MAX) ? NODES_MAX[15:0] : nodes_n;
    wire [15:0] lanes_cfg = (lanes_p == 16'd0) ? 16'd1 : lanes_p;
    // Saturate effective lane count to the parameterized ceiling, sized to 4 bits.
    // Note: 4'd<identifier> is illegal; cast by selecting/capping instead.
    wire [3:0]  lanes_eff = (lanes_cfg > LANES_MAX) ? ((LANES_MAX < 16) ? LANES_MAX : 15) : lanes_cfg[3:0];
    wire [15:0] feat_cfg  = (feat_k_in == 16'd0) ? 16'd1 :
                            (feat_k_in > FEAT_MAX) ? FEAT_MAX[15:0] : feat_k_in;
    wire [31:0] tick_budget_cfg = (tick_budget == 32'd0) ? 32'd64 : tick_budget;

    // Memories for captured features and current state.
    reg signed [QW-1:0] state_mem [0:NODES_MAX-1];
    reg signed [QW-1:0] feat_mem  [0:FEAT_MAX-1];

    localparam int WIN_DEPTH  = NODES_MAX * FEAT_MAX;
    localparam int WRES_DEPTH = NODES_MAX * WRES_SLOTS;

    reg signed [QW-1:0] win_mem  [0:WIN_DEPTH-1];
    reg signed [QW-1:0] wres_val [0:WRES_DEPTH-1];
    reg [15:0]          wres_col_mem [0:WRES_DEPTH-1];

    // Tanh LUT (covers ±3.0 in Q1.15 space).
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
        // Declarations must precede statements for broad tool compatibility
        logic signed [31:0] abs_val;
        logic [31:0]        scaled;
        logic [7:0]         idx;
        abs_val = (val < 0) ? -val : val;
        // Scale Q1.15 value into LUT domain (approx ±3.0)
        scaled = abs_val <<< 1; // multiply by 2
        idx = (scaled[31:15] >= (TANH_TABLE_SIZE-1)) ? (TANH_TABLE_SIZE-1) : scaled[20:15];
        return (val < 0) ? -tanh_lut[idx] : tanh_lut[idx];
    endfunction

    function automatic signed [31:0] mul_q15(input signed [15:0] a, input signed [15:0] b);
        mul_q15 = ({{16{a[15]}}, a} * {{16{b[15]}}, b});
    endfunction

    // Lightweight pseudo-random weight generator based on the seed value.
    function automatic int win_index(input int node, input int feat);
        return node * FEAT_MAX + feat;
    endfunction

    function automatic int wres_index(input int node, input int slot);
        return node * WRES_SLOTS + slot;
    endfunction

    typedef enum logic [1:0] {UP_ACCUM_INPUT=2'd0, UP_ACCUM_REC=2'd1, UP_COMMIT=2'd2} update_phase_t;

    reg [1:0] state;
    reg [15:0] feat_wr_addr;
    reg [31:0] feature_sum_acc;
    reg [31:0] state_checksum;
    reg [15:0] update_idx;
    reg [31:0] tick_counter;
    reg [63:0] seed_latched;
    update_phase_t update_phase;  // Sequential micro-steps keep BRAM usage bounded; see NOV_4_BRAINSTORM for future lane rework.
    reg [15:0] feat_idx;
    reg [$clog2(WRES_SLOTS)-1:0] wres_slot_idx;
    reg signed [31:0] acc_work;

    reg         rc_fault_reg;
    reg         valid_tick_reg;
    reg         out_valid_reg;
    reg [DATAW-1:0] out_data_reg;

    assign s_axis_tready = (state != ST_UPDATE && state != ST_OUTPUT) && en;
    assign m_axis_tdata  = out_data_reg;
    assign m_axis_tvalid = out_valid_reg;
    assign m_axis_tlast  = out_valid_reg;
    assign rc_fault      = rc_fault_reg;
    assign valid_tick    = valid_tick_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= ST_IDLE;
            feat_wr_addr     <= 16'd0;
            feature_sum_acc  <= 32'sd0;
            state_checksum   <= 32'sd0;
            update_idx       <= 16'd0;
            tick_counter     <= 32'd0;
            rc_fault_reg     <= 1'b0;
            valid_tick_reg   <= 1'b0;
            out_valid_reg    <= 1'b0;
            out_data_reg     <= '0;
            seed_latched     <= seed_value;
            update_phase     <= UP_ACCUM_INPUT;
            feat_idx         <= 16'd0;
            wres_slot_idx    <= '0;
            acc_work         <= 32'sd0;
        end else begin
            valid_tick_reg <= 1'b0;

            if (soft_reset || !en) begin
                state            <= ST_IDLE;
                feat_wr_addr     <= 16'd0;
                feature_sum_acc  <= 32'sd0;
                state_checksum   <= 32'sd0;
                update_idx       <= 16'd0;
                tick_counter     <= 32'd0;
                rc_fault_reg     <= 1'b0;
                out_valid_reg    <= 1'b0;
                seed_latched     <= seed_value;
                update_phase     <= UP_ACCUM_INPUT;
                feat_idx         <= 16'd0;
                wres_slot_idx    <= '0;
                acc_work         <= 32'sd0;
            end else begin
                case (state)
                    ST_IDLE: begin
                        feat_wr_addr     <= 16'd0;
                        feature_sum_acc  <= 32'sd0;
                        state_checksum   <= 32'sd0;
                        update_idx       <= 16'd0;
                        tick_counter     <= 32'd0;
                        rc_fault_reg     <= 1'b0;
                        out_valid_reg    <= 1'b0;
                        if (s_axis_tvalid && s_axis_tready) begin
                            state <= ST_CAPTURE;
                        end
                    end

                    ST_CAPTURE: begin
                        // Temp vars declared at block start (avoid 'automatic' in blocks)
                        logic signed [31:0] sum_tmp;
                        logic [15:0]        addr_tmp;
                        if (s_axis_tvalid && s_axis_tready) begin
                            sum_tmp = feature_sum_acc;
                            addr_tmp = feat_wr_addr;
                            for (int lane = 0; lane < DATAW/QW; lane++) begin
                            if (addr_tmp < feat_cfg) begin
                                feat_mem[addr_tmp] <= s_axis_tdata[(lane*QW)+:QW];
                                sum_tmp = sum_tmp + {{(32-QW){s_axis_tdata[(lane*QW)+QW-1]}}, s_axis_tdata[(lane*QW)+:QW]};
                                addr_tmp = addr_tmp + 1;
                            end
                            end
                            feature_sum_acc <= sum_tmp;
                            feat_wr_addr    <= addr_tmp;
                            if (s_axis_tlast) begin
                                state          <= ST_UPDATE;
                                update_idx     <= 16'd0;
                                tick_counter   <= 32'd0;
                                state_checksum <= 32'sd0;
                                update_phase   <= UP_ACCUM_INPUT;
                                feat_idx       <= 16'd0;
                                wres_slot_idx  <= '0;
                                acc_work       <= 32'sd0;
                            end
                        end
                    end

                    ST_UPDATE: begin
                        // Temps declared up-front; synthesis requires explicit types.
                        automatic int win_addr_idx;
                        automatic int wres_idx;
                        automatic int col;
                        automatic logic signed [15:0] prev;
                        automatic logic signed [15:0] tanh_out;
                        automatic logic signed [31:0] prev_ext;
                        automatic logic signed [31:0] alpha_ext;
                        automatic logic signed [31:0] one_minus_alpha;
                        automatic logic signed [31:0] leak_term;
                        automatic logic signed [31:0] drive_term;
                        automatic logic signed [15:0] feature_word;
                        automatic logic signed [15:0] checksum_word;
                        automatic logic signed [31:0] mixed;
                        automatic logic signed [31:0] mixed_ext;
                        automatic logic signed [15:0] mixed_sat;
                        automatic logic signed [31:0] checksum_next;

                        tick_counter <= tick_counter + 1;
                        if (tick_counter >= tick_budget_cfg) begin
                            rc_fault_reg <= 1'b1;
                        end

                        case (update_phase)
                            UP_ACCUM_INPUT: begin
                                if (feat_idx < feat_cfg) begin
                                    win_addr_idx = win_index(update_idx, feat_idx);
                                    if (win_addr_idx < WIN_DEPTH) begin
                                        acc_work <= acc_work + (mul_q15(win_mem[win_addr_idx], feat_mem[feat_idx]) >>> 15);
                                    end
                                    feat_idx <= feat_idx + 1'b1;
                                end else begin
                                    feat_idx      <= 16'd0;
                                    wres_slot_idx <= '0;
                                    update_phase  <= UP_ACCUM_REC;
                                end
                            end

                            UP_ACCUM_REC: begin
                                if (wres_slot_idx < WRES_SLOTS) begin
                                    wres_idx = wres_index(update_idx, wres_slot_idx);
                                    if (wres_idx < WRES_DEPTH) begin
                                        col = wres_col_mem[wres_idx];
                                        if (col < nodes_cfg) begin
                                            acc_work <= acc_work + (mul_q15(wres_val[wres_idx], state_mem[col]) >>> 15);
                                        end
                                    end
                                    wres_slot_idx <= wres_slot_idx + 1'b1;
                                end else begin
                                    update_phase <= UP_COMMIT;
                                end
                            end

                            UP_COMMIT: begin
                                prev           = state_mem[update_idx];
                                tanh_out       = tanh_lookup(acc_work);
                                prev_ext       = {{16{prev[15]}}, prev};
                                alpha_ext      = {{16{alpha_q15[15]}}, alpha_q15};
                                one_minus_alpha= 32'sd32767 - alpha_ext;
                                leak_term      = (prev_ext * one_minus_alpha) >>> 15;
                                drive_term     = ({{16{tanh_out[15]}}, tanh_out} * alpha_ext) >>> 15;
                                mixed          = leak_term + drive_term;
                                mixed_sat      = sat_q15(mixed);
                                mixed_ext      = {{(32-QW){mixed_sat[15]}}, mixed_sat};
                                checksum_next  = state_checksum + mixed_ext;

                                state_mem[update_idx] <= mixed_sat;
                                state_checksum        <= checksum_next;
                                acc_work              <= 32'sd0;
                                wres_slot_idx         <= '0;
                                feat_idx              <= 16'd0;
                                update_phase          <= UP_ACCUM_INPUT;

                                if (update_idx + 1 >= nodes_cfg) begin
                                    feature_word  = feature_sum_acc[30:15];
                                    checksum_word = checksum_next[30:15];
                                    out_data_reg  <= {rho_q15, alpha_q15, checksum_word, feature_word};
                                    out_valid_reg <= 1'b1;
                                    state         <= ST_OUTPUT;
                                end else begin
                                    update_idx <= update_idx + 1'b1;
                                end
                            end
                        endcase
                    end

                    ST_OUTPUT: begin
                        if (m_axis_tready || rc_fault_reg) begin
                            valid_tick_reg <= m_axis_tready && !rc_fault_reg;
                            out_valid_reg  <= 1'b0;
                            state          <= ST_IDLE;
                        end
                    end
                endcase
            end
        end
    end

    function automatic signed [15:0] sat_q15(input signed [31:0] val);
        if (val > 32'sd32767)       sat_q15 = 16'sh7FFF;
        else if (val < -32'sd32768) sat_q15 = 16'sh8000;
        else                        sat_q15 = val[15:0];
    endfunction

    // Handle weight writes
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int idx = 0; idx < WIN_DEPTH; idx++) begin
                win_mem[idx] <= '0;
            end
            for (int idx = 0; idx < WRES_DEPTH; idx++) begin
                wres_val[idx]     <= (idx % WRES_SLOTS == 0) ? 16'sh4000 : '0;
                wres_col_mem[idx] <= idx % WRES_SLOTS == 0 ? idx / WRES_SLOTS : 16'd0;
            end
        end else begin
            if (soft_reset) begin
                // Preserve weights across soft reset.
            end
            if (win_we) begin
                automatic int node;
                automatic int feat;
                automatic int addr;
                node = win_addr[31:16];
                feat = win_addr[15:0];
                addr = win_index(node, feat);
                if (addr < WIN_DEPTH) begin
                    win_mem[addr] <= win_value;
                end
            end
            if (wres_we) begin
                automatic int node;
                automatic int slot;
                automatic int addr;
                node = wres_node;
                slot = wres_slot;
                addr = wres_index(node, slot);
                if (addr < WRES_DEPTH) begin
                    wres_val[addr]     <= wres_value;
                    wres_col_mem[addr] <= wres_col;
                end
            end
        end
    end

endmodule
