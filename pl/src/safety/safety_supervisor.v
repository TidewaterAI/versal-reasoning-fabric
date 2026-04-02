module safety_supervisor(
  input  wire        clk, rst,
  // External interlocks
  input  wire        kill_ext,        // external emergency kill (active high)
  input  wire        limit_over,      // legacy limit input
  // New comparators
  input  wire        photodiode_over, // optical power over-limit comparator
  input  wire        mea_over,        // MEA headstage over-range comparator
  // Watchdog
  input  wire        wdog_kick,       // watchdog kick from MCU
  // Duty/energy accounting (optional)
  input  wire        duty_tick,       // assert 1 per clk when outputs are active
  input  wire [31:0] duty_limit,      // limit in clk ticks; 0 disables check
  input  wire        counters_clear,  // pulse to clear counters
  // Outputs
  output reg         kill_latched,    // drives hard interlock (active high)
  output reg [31:0]  duty_count       // observed accumulated duty (saturating)
);
  reg [23:0] wdog_cnt;
  reg kill_ext_meta;
  reg kill_ext_sync;
  reg limit_over_meta;
  reg limit_over_sync;
  reg photodiode_over_meta;
  reg photodiode_over_sync;
  reg mea_over_meta;
  reg mea_over_sync;

  always @(posedge clk) begin
    if (rst) begin
      kill_ext_meta       <= 1'b0;
      kill_ext_sync       <= 1'b0;
      limit_over_meta     <= 1'b0;
      limit_over_sync     <= 1'b0;
      photodiode_over_meta<= 1'b0;
      photodiode_over_sync<= 1'b0;
      mea_over_meta       <= 1'b0;
      mea_over_sync       <= 1'b0;
    end else begin
      kill_ext_meta        <= kill_ext;
      kill_ext_sync        <= kill_ext_meta;
      limit_over_meta      <= limit_over;
      limit_over_sync      <= limit_over_meta;
      photodiode_over_meta <= photodiode_over;
      photodiode_over_sync <= photodiode_over_meta;
      mea_over_meta        <= mea_over;
      mea_over_sync        <= mea_over_meta;
    end
  end

  // Watchdog + kill latch - consolidated logic with single driver for kill_latched
  always @(posedge clk) begin
    if (rst) begin
      wdog_cnt     <= 0;
      kill_latched <= 1'b0;
    end else begin
      if (wdog_kick) wdog_cnt <= 0;
      else           wdog_cnt <= wdog_cnt + 1;

      // Combined kill condition: external signals, watchdog, or duty limit exceeded
      if (kill_ext_sync || limit_over_sync || photodiode_over_sync || mea_over_sync || wdog_cnt[23] ||
          (duty_limit != 32'd0 && duty_count >= duty_limit)) begin
        kill_latched <= 1'b1;
      end
      // latches until full reset; optionally add unlatch sequence later
    end
  end

  // Duty counter with optional limit
  always @(posedge clk) begin
    if (rst || counters_clear) begin
      duty_count <= 32'd0;
    end else begin
      if (duty_tick && !kill_latched) begin
        if (duty_count != 32'hFFFF_FFFF)
          duty_count <= duty_count + 1'b1;
      end
    end
  end
endmodule
