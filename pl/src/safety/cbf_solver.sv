module cbf_solver #(
    parameter int DATAW = 32,
    parameter int MAX_ITER = 10,
    parameter int LEARNING_RATE_SHIFT = 4 // Divide by 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    
    // Inputs
    input  wire signed [DATAW-1:0] u_ref,       // Desired velocity
    input  wire signed [DATAW-1:0] x_curr,      // Current position
    input  wire signed [DATAW-1:0] x_min,       // Geofence min
    input  wire signed [DATAW-1:0] x_max,       // Geofence max
    
    // Outputs
    output reg  signed [DATAW-1:0] u_safe,      // Safe velocity
    output reg              done,
    output reg              active              // Solver is running
);

    // Internal signals
    reg signed [DATAW-1:0] u_curr;
    reg [3:0] iter_count;
    
    // Declare variables at module level for Vivado compatibility
    logic signed [DATAW-1:0] u_next;
    logic signed [DATAW-1:0] limit_upper;
    logic signed [DATAW-1:0] limit_lower;
    
    // Barrier Function h(x) = (x_max - x) or (x - x_min)
    // We want h(x_next) >= 0
    // x_next approx x_curr + u * dt (assume dt=1 for simplicity)
    // So: x_max - (x_curr + u) >= 0  =>  u <= x_max - x_curr
    // And: (x_curr + u) - x_min >= 0  =>  u >= x_min - x_curr
    
    // Gradient Descent Objective: Minimize J = 0.5 * (u - u_ref)^2
    // Gradient dJ/du = (u - u_ref)
    // Update: u_new = u_old - alpha * (u_old - u_ref)
    // BUT we also need to project onto the feasible set defined by the barriers.
    
    // Since the constraints are simple box constraints on 'u' derived from 'x',
    // we can actually solve this analytically with clamping, but we will implement
    // an iterative approach to demonstrate the "solver" architecture requested,
    // which can be extended to more complex QP later.
    
    // For this specific 1D case, the "Solver" finds the unconstrained minimum (u_ref)
    // and projects it onto [min_safe_u, max_safe_u].
    
    always @(posedge clk) begin
        if (!rst_n) begin
            u_safe <= '0;
            done <= 1'b0;
            active <= 1'b0;
            u_curr <= '0;
            iter_count <= '0;
        end else begin
            if (start) begin
                active <= 1'b1;
                done <= 1'b0;
                u_curr <= u_ref; // Initialize with desired
                iter_count <= '0;
            end else if (active) begin
                // In a real QP solver, we would iterate. 
                // Here we simulate the "search" for a safe control.
                
                // Calculate dynamic limits based on geofence
                // limit_upper = Distance to max wall
                limit_upper = x_max - x_curr;
                // limit_lower = Distance to min wall (negative)
                limit_lower = x_min - x_curr;
                
                // Gradient Step (trivial here as we start at u_ref, but showing structure)
                // u_next = u_curr - (u_curr - u_ref) >> shift; 
                // Since we start at u_ref, the gradient is 0. We just need projection.
                
                u_next = u_curr;
                
                // Projection / Barrier Enforcement
                if (u_next > limit_upper) begin
                    u_next = limit_upper;
                end else if (u_next < limit_lower) begin
                    u_next = limit_lower;
                end
                
                // Check convergence (immediate for this simple case)
                if (iter_count == 0) begin // One pass is enough for box constraints
                    u_safe <= u_next;
                    done <= 1'b1;
                    active <= 1'b0;
                end
                
                iter_count <= iter_count + 1;
            end else begin
                done <= 1'b0;
            end
        end
    end

endmodule
