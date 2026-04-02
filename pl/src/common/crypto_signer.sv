module crypto_signer #(
    parameter int DATAW = 64
)(
    input  wire             clk,
    input  wire             rst_n,
    
    // Data to sign
    input  wire [DATAW-1:0] data_in,
    input  wire             data_valid,
    input  wire [63:0]      timestamp,
    
    // Output Stream (Data + Signature)
    output reg  [DATAW+63:0] signed_packet, // Data + Sig (64-bit mock sig)
    output reg              packet_valid
);

    // Mock Signature: XOR of data and timestamp
    // In a real system, this would be an ECDSA engine output
    
    // External Crypto Chip Interface (Simulation / Stub)
    // In a real system, this would drive I2C/SPI to an ATECC608 or similar.
    
    // Simulation Parameters
    localparam int SIM_DELAY_CYCLES = 100; // Simulate I2C transaction time
    
    typedef enum logic [1:0] {IDLE, SIGNING, DONE} state_t;
    state_t state;
    reg [31:0] timer;
    
    always @(posedge clk) begin
        if (!rst_n) begin
            signed_packet <= '0;
            packet_valid  <= 1'b0;
            state         <= IDLE;
            timer         <= '0;
        end else begin
            case (state)
                IDLE: begin
                    packet_valid <= 1'b0;
                    if (data_valid) begin
                        // Latch data and start "transaction"
                        signed_packet <= {64'h0, data_in}; // Clear sig for now
                        state <= SIGNING;
                        timer <= '0;
                    end
                end
                
                SIGNING: begin
                    if (timer < SIM_DELAY_CYCLES) begin
                        timer <= timer + 1;
                    end else begin
                        // Transaction complete
                        // In real hardware, we would read the signature from the chip here.
                        // For now, generate a "valid" mock signature that looks different from the XOR one.
                        // Let's use a magic constant + data hash to show it's "signed"
                        logic [63:0] mock_ecdsa_sig;
                        
                        // Simple folding hash of the wide input data
                        mock_ecdsa_sig = 64'hDEAD_BEEF_CAFE_F00D;
                        for (int i = 0; i < DATAW/64; i++) begin
                            mock_ecdsa_sig = mock_ecdsa_sig ^ data_in[i*64 +: 64];
                        end
                        // Handle remaining bits if DATAW is not multiple of 64
                        if (DATAW % 64 != 0) begin
                            mock_ecdsa_sig = mock_ecdsa_sig ^ { {(64-(DATAW%64)){1'b0}}, data_in[DATAW-1 -: (DATAW%64)] };
                        end
                        
                        signed_packet[DATAW+63:DATAW] <= mock_ecdsa_sig;
                        state <= DONE;
                    end
                end
                
                DONE: begin
                    packet_valid <= 1'b1;
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
