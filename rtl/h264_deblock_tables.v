// h264_deblock_tables.v -- H.264 alpha/beta/tc0 lookup tables.
// The base tables are the normative 8-bit index 0..51 values, scaled by bit depth.

module h264_deblock_tables #(
    parameter BIT_DEPTH = 8
) (
    input  wire [5:0] index_a,
    input  wire [5:0] index_b,
    input  wire [2:0] bs,
    input  wire       chroma_edge,
    output reg  [BIT_DEPTH:0] alpha,
    output reg  [BIT_DEPTH:0] beta,
    output reg  signed [BIT_DEPTH:0] tc0
);
    function automatic [7:0] alpha_base;
        input [5:0] idx;
        begin
            case (idx)
                6'd16: alpha_base = 8'd4;   6'd17: alpha_base = 8'd4;
                6'd18: alpha_base = 8'd5;   6'd19: alpha_base = 8'd6;
                6'd20: alpha_base = 8'd7;   6'd21: alpha_base = 8'd8;
                6'd22: alpha_base = 8'd9;   6'd23: alpha_base = 8'd10;
                6'd24: alpha_base = 8'd12;  6'd25: alpha_base = 8'd13;
                6'd26: alpha_base = 8'd15;  6'd27: alpha_base = 8'd17;
                6'd28: alpha_base = 8'd20;  6'd29: alpha_base = 8'd22;
                6'd30: alpha_base = 8'd25;  6'd31: alpha_base = 8'd28;
                6'd32: alpha_base = 8'd32;  6'd33: alpha_base = 8'd36;
                6'd34: alpha_base = 8'd40;  6'd35: alpha_base = 8'd45;
                6'd36: alpha_base = 8'd50;  6'd37: alpha_base = 8'd56;
                6'd38: alpha_base = 8'd63;  6'd39: alpha_base = 8'd71;
                6'd40: alpha_base = 8'd80;  6'd41: alpha_base = 8'd90;
                6'd42: alpha_base = 8'd101; 6'd43: alpha_base = 8'd113;
                6'd44: alpha_base = 8'd127; 6'd45: alpha_base = 8'd144;
                6'd46: alpha_base = 8'd162; 6'd47: alpha_base = 8'd182;
                6'd48: alpha_base = 8'd203; 6'd49: alpha_base = 8'd226;
                6'd50: alpha_base = 8'd255; 6'd51: alpha_base = 8'd255;
                default: alpha_base = 8'd0;
            endcase
        end
    endfunction

    function automatic [7:0] beta_base;
        input [5:0] idx;
        begin
            case (idx)
                6'd16: beta_base = 8'd2;  6'd17: beta_base = 8'd2;
                6'd18: beta_base = 8'd2;  6'd19: beta_base = 8'd3;
                6'd20: beta_base = 8'd3;  6'd21: beta_base = 8'd3;
                6'd22: beta_base = 8'd3;  6'd23: beta_base = 8'd4;
                6'd24: beta_base = 8'd4;  6'd25: beta_base = 8'd4;
                6'd26: beta_base = 8'd6;  6'd27: beta_base = 8'd6;
                6'd28: beta_base = 8'd7;  6'd29: beta_base = 8'd7;
                6'd30: beta_base = 8'd8;  6'd31: beta_base = 8'd8;
                6'd32: beta_base = 8'd9;  6'd33: beta_base = 8'd9;
                6'd34: beta_base = 8'd10; 6'd35: beta_base = 8'd10;
                6'd36: beta_base = 8'd11; 6'd37: beta_base = 8'd11;
                6'd38: beta_base = 8'd12; 6'd39: beta_base = 8'd12;
                6'd40: beta_base = 8'd13; 6'd41: beta_base = 8'd13;
                6'd42: beta_base = 8'd14; 6'd43: beta_base = 8'd14;
                6'd44: beta_base = 8'd15; 6'd45: beta_base = 8'd15;
                6'd46: beta_base = 8'd16; 6'd47: beta_base = 8'd16;
                6'd48: beta_base = 8'd17; 6'd49: beta_base = 8'd17;
                6'd50: beta_base = 8'd18; 6'd51: beta_base = 8'd18;
                default: beta_base = 8'd0;
            endcase
        end
    endfunction

    function automatic signed [7:0] tc0_base;
        input [5:0] idx;
        input [2:0] bs_i;
        begin
            if (bs_i == 3'd0) begin
                tc0_base = -8'sd1;
            end else if (bs_i >= 3'd4) begin
                tc0_base = 8'sd0;
            end else begin
                case (idx)
                    6'd0, 6'd1, 6'd2, 6'd3, 6'd4, 6'd5, 6'd6, 6'd7,
                    6'd8, 6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14,
                    6'd15, 6'd16:
                        tc0_base = 8'sd0;
                    6'd17, 6'd18, 6'd19, 6'd20:
                        tc0_base = (bs_i == 3'd3) ? 8'sd1 : 8'sd0;
                    6'd21, 6'd22:
                        tc0_base = (bs_i == 3'd1) ? 8'sd0 : 8'sd1;
                    6'd23, 6'd24, 6'd25, 6'd26:
                        tc0_base = 8'sd1;
                    6'd27, 6'd28, 6'd29, 6'd30:
                        tc0_base = (bs_i == 3'd3) ? 8'sd2 : 8'sd1;
                    6'd31, 6'd32:
                        tc0_base = (bs_i == 3'd1) ? 8'sd1 : ((bs_i == 3'd2) ? 8'sd2 : 8'sd3);
                    6'd33:
                        tc0_base = (bs_i == 3'd1) ? 8'sd2 : ((bs_i == 3'd2) ? 8'sd2 : 8'sd3);
                    6'd34:
                        tc0_base = (bs_i == 3'd1) ? 8'sd2 : ((bs_i == 3'd2) ? 8'sd2 : 8'sd4);
                    6'd35, 6'd36:
                        tc0_base = (bs_i == 3'd1) ? 8'sd2 : ((bs_i == 3'd2) ? 8'sd3 : 8'sd4);
                    6'd37:
                        tc0_base = (bs_i == 3'd1) ? 8'sd3 : ((bs_i == 3'd2) ? 8'sd3 : 8'sd5);
                    6'd38, 6'd39:
                        tc0_base = (bs_i == 3'd1) ? 8'sd3 : ((bs_i == 3'd2) ? 8'sd4 : 8'sd6);
                    6'd40:
                        tc0_base = (bs_i == 3'd1) ? 8'sd4 : ((bs_i == 3'd2) ? 8'sd5 : 8'sd7);
                    6'd41:
                        tc0_base = (bs_i == 3'd1) ? 8'sd4 : ((bs_i == 3'd2) ? 8'sd5 : 8'sd8);
                    6'd42:
                        tc0_base = (bs_i == 3'd1) ? 8'sd4 : ((bs_i == 3'd2) ? 8'sd6 : 8'sd9);
                    6'd43:
                        tc0_base = (bs_i == 3'd1) ? 8'sd5 : ((bs_i == 3'd2) ? 8'sd7 : 8'sd10);
                    6'd44:
                        tc0_base = (bs_i == 3'd1) ? 8'sd6 : ((bs_i == 3'd2) ? 8'sd8 : 8'sd11);
                    6'd45:
                        tc0_base = (bs_i == 3'd1) ? 8'sd6 : ((bs_i == 3'd2) ? 8'sd8 : 8'sd13);
                    6'd46:
                        tc0_base = (bs_i == 3'd1) ? 8'sd7 : ((bs_i == 3'd2) ? 8'sd10 : 8'sd14);
                    6'd47:
                        tc0_base = (bs_i == 3'd1) ? 8'sd8 : ((bs_i == 3'd2) ? 8'sd11 : 8'sd16);
                    6'd48:
                        tc0_base = (bs_i == 3'd1) ? 8'sd9 : ((bs_i == 3'd2) ? 8'sd12 : 8'sd18);
                    6'd49:
                        tc0_base = (bs_i == 3'd1) ? 8'sd10 : ((bs_i == 3'd2) ? 8'sd13 : 8'sd20);
                    6'd50:
                        tc0_base = (bs_i == 3'd1) ? 8'sd11 : ((bs_i == 3'd2) ? 8'sd15 : 8'sd23);
                    6'd51:
                        tc0_base = (bs_i == 3'd1) ? 8'sd13 : ((bs_i == 3'd2) ? 8'sd17 : 8'sd25);
                    default: tc0_base = 8'sd0;
                endcase
            end
        end
    endfunction

    function automatic [BIT_DEPTH:0] scale_unsigned;
        input [7:0] base;
        integer v;
        begin
            if (BIT_DEPTH > 8)
                v = base << (BIT_DEPTH - 8);
            else
                v = base;
            scale_unsigned = v[BIT_DEPTH:0];
        end
    endfunction

    function automatic signed [BIT_DEPTH:0] scale_signed;
        input signed [7:0] base;
        integer v;
        begin
            if (base < 0)
                v = -1;
            else if (BIT_DEPTH > 8)
                v = base << (BIT_DEPTH - 8);
            else
                v = base;
            scale_signed = v[BIT_DEPTH:0];
        end
    endfunction

    always @(*) begin
        alpha = scale_unsigned(alpha_base(index_a));
        beta  = scale_unsigned(beta_base(index_b));
        tc0   = scale_signed(tc0_base(index_a, bs));
    end
endmodule
