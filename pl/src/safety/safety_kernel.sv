module safety_kernel #(
    parameter int DATAW = 32
)(
    input  wire             clk,
    input  wire             rst_n,

    // Configuration (Safe Set Limits)
    input  wire [DATAW-1:0] max_velocity,
    input  wire [DATAW-1:0] max_acceleration,
    input  wire [DATAW-1:0] geofence_min_x,
    input  wire [DATAW-1:0] geofence_max_x,

    // Inputs
    // CDC NOTE: candidate_velocity, current_position_x, and candidate_valid are
    // SYNCHRONOUS to clk. They originate from AXI-Lite registers (hub_control_regs)
    // which share the same clock domain (clk_fpga_0 / clk_100).
    // The 2-FF synchronizer on candidate_valid adds latency but is kept for safety
    // in case these signals are ever sourced from an external asynchronous domain.
    // If that happens, candidate_velocity and current_position_x would also need
    // proper CDC handling (e.g., handshake protocol or gray-coded bus sync).
    input  wire [DATAW-1:0] candidate_velocity,
    input  wire [DATAW-1:0] current_position_x,
    input  wire             candidate_valid,
    
    // Outputs
    output reg  [DATAW-1:0] safe_velocity,
    output reg              safe_valid,
    output reg              intervention_active,
    output reg  [31:0]      violation_count
);

    // CBF Solver Integration
    
    wire signed [DATAW-1:0] solver_out;
    wire solver_done;
    reg  solver_start;
    reg  candidate_valid_meta;
    reg  candidate_valid_sync;
    reg  [DATAW-1:0] candidate_velocity_q;
    reg  [DATAW-1:0] current_position_x_q;
    
    cbf_solver #(
        .DATAW(DATAW)
    ) u_solver (
        .clk(clk),
        .rst_n(rst_n),
        .start(solver_start),
        .u_ref(candidate_velocity_q),
        .x_curr(current_position_x_q),
        .x_min(geofence_min_x),
        .x_max(geofence_max_x),
        .u_safe(solver_out),
        .done(solver_done),
        .active()
    );
    
    // State Machine for handling solver latency
    typedef enum logic [1:0] {IDLE, LATCH, SOLVING, OUTPUT} state_t;
    state_t state;
    
    // Declare variables at module level for Vivado compatibility
    logic intervention_next;
    logic [DATAW-1:0] final_vel_next;

    always_comb begin
        final_vel_next = solver_out;
        intervention_next = (solver_out != candidate_velocity_q);

        if ($signed(final_vel_next) > $signed(max_velocity)) begin
            final_vel_next = max_velocity;
            intervention_next = 1'b1;
        end else if ($signed(final_vel_next) < -$signed(max_velocity)) begin
            final_vel_next = -$signed(max_velocity);
            intervention_next = 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            safe_velocity       <= '0;
            safe_valid          <= 1'b0;
            intervention_active <= 1'b0;
            violation_count     <= '0;
            solver_start        <= 1'b0;
            candidate_valid_meta <= 1'b0;
            candidate_valid_sync <= 1'b0;
            candidate_velocity_q <= '0;
            current_position_x_q <= '0;
            state               <= IDLE;
        end else begin
            candidate_valid_meta <= candidate_valid;
            candidate_valid_sync <= candidate_valid_meta;
            solver_start <= 1'b0;
            case (state)
                IDLE: begin
                    safe_valid <= 1'b0;
                    if (candidate_valid_sync) begin
                        candidate_velocity_q <= candidate_velocity;
                        current_position_x_q <= current_position_x;
                        state <= LATCH;
                    end
                end

                LATCH: begin
                    solver_start <= 1'b1;
                    state <= SOLVING;
                end

                SOLVING: begin
                    if (solver_done) begin
                        state <= OUTPUT;
                    end
                end
                
                OUTPUT: begin
                    safe_velocity       <= final_vel_next;
                    safe_valid          <= 1'b1;
                    intervention_active <= intervention_next;
                    
                    if (intervention_next) begin
                        violation_count <= violation_count + 1;
                    end
                    
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
