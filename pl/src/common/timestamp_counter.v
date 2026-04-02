// Timestamp counter: seconds + ticks with optional PPS discipline
// - Increments ticks each clk; when ticks == TICKS_PER_SEC-1, ticks resets and seconds++
// - If pps_sync asserted (1-cycle pulse), realign ticks to 0 and optionally increment seconds
module timestamp_counter #(
  parameter TICKS_PER_SEC = 1000000
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        pps_sync,     // optional 1PPS pulse (one clk cycle) to discipline counter
  output reg [63:0]  seconds,
  output reg [31:0]  ticks
);
  localparam TICKS_W = 32;
  always @(posedge clk) begin
    if (rst) begin
      seconds <= 64'd0;
      ticks   <= 32'd0;
    end else begin
      if (pps_sync) begin
        seconds <= seconds + 1'b1;
        ticks   <= 32'd0;
      end else begin
        if (ticks == TICKS_PER_SEC-1) begin
          ticks   <= 32'd0;
          seconds <= seconds + 1'b1;
        end else begin
          ticks <= ticks + 1'b1;
        end
      end
    end
  end
endmodule

