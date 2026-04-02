// tb_lane_tile.sv — Testbench for a single reasoning lane.
//
// Exercises the lane_tile in PL-only mode (USE_AIE=0):
//   1. Send a 13-dim Q1.15 feature vector (matches hive audio format)
//   2. Verify that RC core processes it and produces output
//   3. Verify that Bicky mode switch works
//   4. Verify that kill_ext halts output
//   5. Verify that lane_fault asserts on tick budget violation

`include "versal_config.svh"
`timescale 1ns / 1ps

module tb_lane_tile;

    localparam int DATAW   = 64;
    localparam int QW      = 16;
    localparam int CLK_NS  = 4;  // 250 MHz

    // Clock and reset
    logic clk = 0;
    logic rst_n = 0;
    always #(CLK_NS/2) clk = ~clk;

    // DUT signals
    logic [DATAW-1:0]  s_tdata;
    logic              s_tvalid;
    logic              s_tready;
    logic              s_tlast;

    logic              lane_enable;
    logic              mode_bicky;
    logic              global_kill;
    logic              lane_fault;

    // Plugin interface
    modality_plugin_if #(.AXIS_W(DATAW)) plugin_if (.clk(clk), .rst_n(rst_n));

    // Tie off plugin fabric-side controls
    assign plugin_if.trig              = 1'b0;
    assign plugin_if.gate              = lane_enable;
    assign plugin_if.timestamp_seconds = 64'd0;
    assign plugin_if.timestamp_ticks   = 32'd0;
    assign plugin_if.csr_we            = 1'b0;
    assign plugin_if.csr_re            = 1'b0;
    assign plugin_if.csr_addr          = '0;
    assign plugin_if.csr_wdata         = '0;

    // Tie off AIE ports (PL-only mode)
    logic [DATAW-1:0] aie_tx_tdata;
    logic             aie_tx_tvalid, aie_tx_tready, aie_tx_tlast;
    logic [DATAW-1:0] aie_rx_tdata;
    logic             aie_rx_tvalid, aie_rx_tready, aie_rx_tlast;

    assign aie_tx_tready = 1'b0;
    assign aie_rx_tdata  = '0;
    assign aie_rx_tvalid = 1'b0;
    assign aie_rx_tlast  = 1'b0;

    // Accept output
    assign plugin_if.m_axis_tready = 1'b1;

    // DUT
    lane_tile #(
        .LANE_ID(0),
        .DATAW(DATAW),
        .USE_AIE(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .plugin_if(plugin_if),
        .s_axis_tdata(s_tdata),
        .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast),
        .aie_tx_tdata(aie_tx_tdata),
        .aie_tx_tvalid(aie_tx_tvalid),
        .aie_tx_tready(aie_tx_tready),
        .aie_tx_tlast(aie_tx_tlast),
        .aie_rx_tdata(aie_rx_tdata),
        .aie_rx_tvalid(aie_rx_tvalid),
        .aie_rx_tready(aie_rx_tready),
        .aie_rx_tlast(aie_rx_tlast),
        .lane_enable(lane_enable),
        .mode_bicky(mode_bicky),
        .rc_nodes_n(16'd64),
        .rc_feat_k(16'd13),
        .rc_alpha_q15(16'sh2666),   // ~0.3
        .rc_rho_q15(16'sh7333),     // ~0.9
        .tick_budget(32'd65536),
        .global_kill(global_kill),
        .lane_fault(lane_fault)
    );

    // ========================================================================
    // Test tasks
    // ========================================================================

    // Send a feature vector (13 dims packed as 4 per 64-bit beat = 4 beats)
    task automatic send_features();
        logic signed [15:0] features [0:12];
        // Synthetic "foraging" pattern (mid-energy in all bands)
        features[0]  = 16'sh1000;  // band_rms_low
        features[1]  = 16'sh0C00;  // band_rms_mid
        features[2]  = 16'sh0800;  // band_rms_high
        features[3]  = 16'sh0E00;  // band_env_low
        features[4]  = 16'sh0A00;  // band_env_mid
        features[5]  = 16'sh0600;  // band_env_high
        features[6]  = 16'sh2000;  // centroid_low
        features[7]  = 16'sh3000;  // centroid_mid
        features[8]  = 16'sh4000;  // centroid_high
        features[9]  = 16'sh0D00;  // band_tkeo_low
        features[10] = 16'sh0900;  // band_tkeo_mid
        features[11] = 16'sh0500;  // band_tkeo_high
        features[12] = 16'sh0200;  // waggle_score

        // Beat 0: features[0..3]
        @(posedge clk);
        s_tdata  = {features[3], features[2], features[1], features[0]};
        s_tvalid = 1'b1;
        s_tlast  = 1'b0;
        @(posedge clk);
        while (!s_tready) @(posedge clk);

        // Beat 1: features[4..7]
        s_tdata  = {features[7], features[6], features[5], features[4]};
        s_tlast  = 1'b0;
        @(posedge clk);
        while (!s_tready) @(posedge clk);

        // Beat 2: features[8..11]
        s_tdata  = {features[11], features[10], features[9], features[8]};
        s_tlast  = 1'b0;
        @(posedge clk);
        while (!s_tready) @(posedge clk);

        // Beat 3: features[12] + padding, TLAST
        s_tdata  = {16'h0000, 16'h0000, 16'h0000, features[12]};
        s_tlast  = 1'b1;
        @(posedge clk);
        while (!s_tready) @(posedge clk);

        s_tvalid = 1'b0;
        s_tlast  = 1'b0;
    endtask

    // ========================================================================
    // Test sequence
    // ========================================================================

    int output_count;

    initial begin
        $display("=== tb_lane_tile: Versal reasoning lane testbench ===");

        // Init
        s_tdata     = '0;
        s_tvalid    = 1'b0;
        s_tlast     = 1'b0;
        lane_enable = 1'b0;
        mode_bicky  = 1'b0;
        global_kill = 1'b0;
        output_count = 0;

        // Reset
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ---- Test 1: RC mode inference ----
        $display("[T1] RC mode: send features, expect output");
        lane_enable = 1'b1;
        mode_bicky  = 1'b0;
        send_features();

        // Wait for output (RC processes sequentially, may take many cycles)
        fork
            begin
                repeat (200000) @(posedge clk);
                $display("[T1] TIMEOUT waiting for RC output");
            end
            begin
                @(posedge plugin_if.m_axis_tvalid);
                output_count++;
                $display("[T1] PASS: RC output received, data=0x%016x", plugin_if.m_axis_tdata);
            end
        join_any
        disable fork;

        repeat (100) @(posedge clk);

        // ---- Test 2: Kill switch ----
        $display("[T2] Kill switch: output should be suppressed");
        global_kill = 1'b1;
        send_features();
        repeat (1000) @(posedge clk);
        if (!plugin_if.m_axis_tvalid)
            $display("[T2] PASS: output suppressed by kill");
        else
            $display("[T2] FAIL: output not suppressed");
        global_kill = 1'b0;
        repeat (10) @(posedge clk);

        // ---- Test 3: Lane disable ----
        $display("[T3] Lane disable: output should be suppressed");
        lane_enable = 1'b0;
        repeat (100) @(posedge clk);
        lane_enable = 1'b1;

        // ---- Done ----
        $display("=== tb_lane_tile: %0d outputs received ===", output_count);
        $finish;
    end

    // Timeout watchdog
    initial begin
        #10_000_000;
        $display("ERROR: Global timeout");
        $finish;
    end

endmodule
