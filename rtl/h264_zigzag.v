// h264_zigzag.v — Zigzag Scan Reordering for 4x4 block
// Reorders quantized coefficients into zigzag scan order
// Computes total_coeffs, trailing_ones, last non-zero index

module h264_zigzag (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Input: 4x4 quantized levels in raster order (256 bits = 16 * 16-bit signed)
    input  wire [255:0] in_flat,

    // Output: coefficients in scan order (256 bits)
    output reg  [255:0] scan_flat,

    output reg  [4:0]  total_coeffs,
    output reg  [1:0]  trailing_ones,
    output reg  [3:0]  last_nonzero_idx
);

    // Zigzag table: scan position → raster position
    function [3:0] zz;
        input [3:0] s;
        case (s)
            4'd0:  zz = 4'd0;
            4'd1:  zz = 4'd1;
            4'd2:  zz = 4'd4;
            4'd3:  zz = 4'd8;
            4'd4:  zz = 4'd5;
            4'd5:  zz = 4'd2;
            4'd6:  zz = 4'd3;
            4'd7:  zz = 4'd6;
            4'd8:  zz = 4'd9;
            4'd9:  zz = 4'd12;
            4'd10: zz = 4'd13;
            4'd11: zz = 4'd10;
            4'd12: zz = 4'd7;
            4'd13: zz = 4'd11;
            4'd14: zz = 4'd14;
            4'd15: zz = 4'd15;
            default: zz = 4'd0;
        endcase
    endfunction

    reg [2:0] state;
    localparam S_IDLE  = 3'd0;
    localparam S_SCAN  = 3'd1;
    localparam S_STATS = 3'd2;
    localparam S_DONE  = 3'd3;

    reg [4:0] idx;
    reg [4:0] tc;
    reg [3:0] last_nz;
    reg [1:0] t1;
    reg       t1_stop;
    reg signed [15:0] val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            done            <= 1'b0;
            total_coeffs    <= 5'd0;
            trailing_ones   <= 2'd0;
            last_nonzero_idx <= 4'd0;
            scan_flat       <= 256'd0;
            idx             <= 5'd0;
            tc              <= 5'd0;
            last_nz         <= 4'd0;
            t1              <= 2'd0;
            t1_stop         <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state   <= S_SCAN;
                        idx     <= 5'd0;
                        tc      <= 5'd0;
                        last_nz <= 4'd0;
                    end
                end

                // verilator lint_off BLKSEQ
                S_SCAN: begin
                    val = $signed(in_flat[zz(idx[3:0])*16 +: 16]);
                    scan_flat[idx[3:0]*16 +: 16] <= val;

                    if (val != 16'sd0) begin
                        tc      <= tc + 5'd1;
                        last_nz <= idx[3:0];
                    end

                    if (idx == 5'd15) begin
                        if (tc == 5'd0 && val == 16'sd0) begin
                            // No non-zero coefficients at all; skip stats
                            total_coeffs     <= 5'd0;
                            trailing_ones    <= 2'd0;
                            last_nonzero_idx <= 4'd0;
                            state            <= S_DONE;
                        end else begin
                            state   <= S_STATS;
                            // Use the effective last non-zero position.
                            // If current val (idx=15) is non-zero, last_nz is
                            // being updated to 15 this cycle (non-blocking), so
                            // we must use 15 directly. Otherwise, use last_nz
                            // which holds the position from a prior cycle.
                            idx     <= (val != 16'sd0) ? 5'd15 : {1'b0, last_nz};
                            t1      <= 2'd0;
                            t1_stop <= 1'b0;
                        end
                    end else begin
                        idx <= idx + 5'd1;
                    end
                end
                // verilator lint_on BLKSEQ

                // Count trailing ones: scan from last non-zero backward
                // verilator lint_off BLKSEQ
                S_STATS: begin
                    val = $signed(scan_flat[idx[3:0]*16 +: 16]);
                    if (!t1_stop && val != 16'sd0) begin
                        if ((val == 16'sd1 || val == -16'sd1) && t1 < 2'd3) begin
                            t1 <= t1 + 2'd1;
                        end else begin
                            t1_stop <= 1'b1;
                        end
                    end

                    if (idx == 5'd0) begin
                        total_coeffs     <= tc;
                        trailing_ones    <= t1;
                        last_nonzero_idx <= last_nz;
                        state            <= S_DONE;
                    end else begin
                        idx <= idx - 5'd1;
                    end
                end
                // verilator lint_on BLKSEQ

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
