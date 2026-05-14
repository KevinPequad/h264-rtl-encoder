// h264_zigzag8x8_cavlc.v — Zigzag scan reordering for 8x8 luma transform CAVLC slices
//
// This module takes a full 8x8 block of quantized coefficients in raster order,
// selects one of the four 4x4 CAVLC syntax blocks inside the 8x8 block, and
// emits the coefficients in the scan order used by H.264 CAVLC for 8x8 transform.

module h264_zigzag8x8_cavlc #(
    parameter BIT_DEPTH = 8,
    parameter QW = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Full 8x8 quantized coefficients in raster order (64 * QW bits).
    input  wire [64*QW-1:0] in_flat,

    // Which 4x4 syntax block inside the 8x8 transform block (0..3).
    input  wire [1:0]  sub_block_idx,

    // Output coefficients in scan order for the selected 4x4 syntax block.
    output reg  [255:0] scan_flat,

    output reg  [4:0]  total_coeffs,
    output reg  [1:0]  trailing_ones,
    output reg  [3:0]  last_nonzero_idx
);

    function [5:0] zz8;
        input [1:0] blk;
        input [3:0] s;
        begin
            case ({blk, s})
            6'd0: zz8 = 6'd0;
            6'd1: zz8 = 6'd9;
            6'd2: zz8 = 6'd17;
            6'd3: zz8 = 6'd18;
            6'd4: zz8 = 6'd12;
            6'd5: zz8 = 6'd40;
            6'd6: zz8 = 6'd27;
            6'd7: zz8 = 6'd7;
            6'd8: zz8 = 6'd35;
            6'd9: zz8 = 6'd57;
            6'd10: zz8 = 6'd29;
            6'd11: zz8 = 6'd30;
            6'd12: zz8 = 6'd58;
            6'd13: zz8 = 6'd38;
            6'd14: zz8 = 6'd53;
            6'd15: zz8 = 6'd47;
            6'd16: zz8 = 6'd1;
            6'd17: zz8 = 6'd2;
            6'd18: zz8 = 6'd24;
            6'd19: zz8 = 6'd11;
            6'd20: zz8 = 6'd19;
            6'd21: zz8 = 6'd48;
            6'd22: zz8 = 6'd20;
            6'd23: zz8 = 6'd14;
            6'd24: zz8 = 6'd42;
            6'd25: zz8 = 6'd50;
            6'd26: zz8 = 6'd22;
            6'd27: zz8 = 6'd37;
            6'd28: zz8 = 6'd59;
            6'd29: zz8 = 6'd31;
            6'd30: zz8 = 6'd60;
            6'd31: zz8 = 6'd55;
            6'd32: zz8 = 6'd8;
            6'd33: zz8 = 6'd3;
            6'd34: zz8 = 6'd32;
            6'd35: zz8 = 6'd4;
            6'd36: zz8 = 6'd26;
            6'd37: zz8 = 6'd41;
            6'd38: zz8 = 6'd13;
            6'd39: zz8 = 6'd21;
            6'd40: zz8 = 6'd49;
            6'd41: zz8 = 6'd43;
            6'd42: zz8 = 6'd15;
            6'd43: zz8 = 6'd44;
            6'd44: zz8 = 6'd52;
            6'd45: zz8 = 6'd39;
            6'd46: zz8 = 6'd61;
            6'd47: zz8 = 6'd62;
            6'd48: zz8 = 6'd16;
            6'd49: zz8 = 6'd10;
            6'd50: zz8 = 6'd25;
            6'd51: zz8 = 6'd5;
            6'd52: zz8 = 6'd33;
            6'd53: zz8 = 6'd34;
            6'd54: zz8 = 6'd6;
            6'd55: zz8 = 6'd28;
            6'd56: zz8 = 6'd56;
            6'd57: zz8 = 6'd36;
            6'd58: zz8 = 6'd23;
            6'd59: zz8 = 6'd51;
            6'd60: zz8 = 6'd45;
            6'd61: zz8 = 6'd46;
            6'd62: zz8 = 6'd54;
            6'd63: zz8 = 6'd63;
                default: zz8 = 6'd0;
            endcase
        end
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
    reg signed [QW-1:0] val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            done             <= 1'b0;
            total_coeffs     <= 5'd0;
            trailing_ones    <= 2'd0;
            last_nonzero_idx <= 4'd0;
            scan_flat        <= 256'd0;
            idx              <= 5'd0;
            tc               <= 5'd0;
            last_nz          <= 4'd0;
            t1               <= 2'd0;
            t1_stop          <= 1'b0;
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
                    val = $signed(in_flat[zz8(sub_block_idx, idx[3:0])*QW +: QW]);
                    scan_flat[idx[3:0]*16 +: 16] <= val[15:0];
                    if (val != {QW{1'b0}}) begin
                        tc      <= tc + 5'd1;
                        last_nz <= idx[3:0];
                    end
                    if (idx == 5'd15) begin
                        if (tc == 5'd0 && val == {QW{1'b0}}) begin
                            total_coeffs     <= 5'd0;
                            trailing_ones    <= 2'd0;
                            last_nonzero_idx <= 4'd0;
                            state            <= S_DONE;
                        end else begin
                            state   <= S_STATS;
                            idx     <= (val != {QW{1'b0}}) ? 5'd15 : {1'b0, last_nz};
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
                        total_coeffs <= tc;
                        if (!t1_stop && val != 16'sd0 && (val == 16'sd1 || val == -16'sd1) && t1 < 2'd3)
                            trailing_ones <= t1 + 2'd1;
                        else
                            trailing_ones <= t1;
                        last_nonzero_idx <= last_nz;
                        state <= S_DONE;
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
