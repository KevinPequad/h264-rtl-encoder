// h264_zigzag8x8.v — standalone H.264 8x8 frame/field scan and coefficient stats.
// Row-major scan maps match the H.264 scan order; x264 macroblock.h stores transposed scan tables.

module h264_zigzag8x8 #(
    parameter QW = 32
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  done,
    input  wire field_scan,
    input  wire [64*QW-1:0] in_flat,
    output reg  [64*QW-1:0] scan_flat,
    output reg  [6:0] total_coeffs,
    output reg  [1:0] trailing_ones,
    output reg  [5:0] last_nonzero_idx
);
    function [5:0] zz_frame;
        input [5:0] s;
        begin
            case (s)
                6'd0:zz_frame=6'd0; 6'd1:zz_frame=6'd1; 6'd2:zz_frame=6'd8; 6'd3:zz_frame=6'd16;
                6'd4:zz_frame=6'd9; 6'd5:zz_frame=6'd2; 6'd6:zz_frame=6'd3; 6'd7:zz_frame=6'd10;
                6'd8:zz_frame=6'd17; 6'd9:zz_frame=6'd24; 6'd10:zz_frame=6'd32; 6'd11:zz_frame=6'd25;
                6'd12:zz_frame=6'd18; 6'd13:zz_frame=6'd11; 6'd14:zz_frame=6'd4; 6'd15:zz_frame=6'd5;
                6'd16:zz_frame=6'd12; 6'd17:zz_frame=6'd19; 6'd18:zz_frame=6'd26; 6'd19:zz_frame=6'd33;
                6'd20:zz_frame=6'd40; 6'd21:zz_frame=6'd48; 6'd22:zz_frame=6'd41; 6'd23:zz_frame=6'd34;
                6'd24:zz_frame=6'd27; 6'd25:zz_frame=6'd20; 6'd26:zz_frame=6'd13; 6'd27:zz_frame=6'd6;
                6'd28:zz_frame=6'd7; 6'd29:zz_frame=6'd14; 6'd30:zz_frame=6'd21; 6'd31:zz_frame=6'd28;
                6'd32:zz_frame=6'd35; 6'd33:zz_frame=6'd42; 6'd34:zz_frame=6'd49; 6'd35:zz_frame=6'd56;
                6'd36:zz_frame=6'd57; 6'd37:zz_frame=6'd50; 6'd38:zz_frame=6'd43; 6'd39:zz_frame=6'd36;
                6'd40:zz_frame=6'd29; 6'd41:zz_frame=6'd22; 6'd42:zz_frame=6'd15; 6'd43:zz_frame=6'd23;
                6'd44:zz_frame=6'd30; 6'd45:zz_frame=6'd37; 6'd46:zz_frame=6'd44; 6'd47:zz_frame=6'd51;
                6'd48:zz_frame=6'd58; 6'd49:zz_frame=6'd59; 6'd50:zz_frame=6'd52; 6'd51:zz_frame=6'd45;
                6'd52:zz_frame=6'd38; 6'd53:zz_frame=6'd31; 6'd54:zz_frame=6'd39; 6'd55:zz_frame=6'd46;
                6'd56:zz_frame=6'd53; 6'd57:zz_frame=6'd60; 6'd58:zz_frame=6'd61; 6'd59:zz_frame=6'd54;
                6'd60:zz_frame=6'd47; 6'd61:zz_frame=6'd55; 6'd62:zz_frame=6'd62; default:zz_frame=6'd63;
            endcase
        end
    endfunction
    function [5:0] zz_field;
        input [5:0] s;
        begin
            case (s)
                6'd0:zz_field=6'd0; 6'd1:zz_field=6'd8; 6'd2:zz_field=6'd16; 6'd3:zz_field=6'd1;
                6'd4:zz_field=6'd9; 6'd5:zz_field=6'd24; 6'd6:zz_field=6'd32; 6'd7:zz_field=6'd17;
                6'd8:zz_field=6'd2; 6'd9:zz_field=6'd25; 6'd10:zz_field=6'd40; 6'd11:zz_field=6'd48;
                6'd12:zz_field=6'd56; 6'd13:zz_field=6'd33; 6'd14:zz_field=6'd10; 6'd15:zz_field=6'd3;
                6'd16:zz_field=6'd18; 6'd17:zz_field=6'd41; 6'd18:zz_field=6'd49; 6'd19:zz_field=6'd57;
                6'd20:zz_field=6'd26; 6'd21:zz_field=6'd11; 6'd22:zz_field=6'd4; 6'd23:zz_field=6'd19;
                6'd24:zz_field=6'd34; 6'd25:zz_field=6'd42; 6'd26:zz_field=6'd50; 6'd27:zz_field=6'd58;
                6'd28:zz_field=6'd27; 6'd29:zz_field=6'd12; 6'd30:zz_field=6'd5; 6'd31:zz_field=6'd20;
                6'd32:zz_field=6'd35; 6'd33:zz_field=6'd43; 6'd34:zz_field=6'd51; 6'd35:zz_field=6'd59;
                6'd36:zz_field=6'd28; 6'd37:zz_field=6'd13; 6'd38:zz_field=6'd6; 6'd39:zz_field=6'd21;
                6'd40:zz_field=6'd36; 6'd41:zz_field=6'd44; 6'd42:zz_field=6'd52; 6'd43:zz_field=6'd60;
                6'd44:zz_field=6'd29; 6'd45:zz_field=6'd14; 6'd46:zz_field=6'd22; 6'd47:zz_field=6'd37;
                6'd48:zz_field=6'd45; 6'd49:zz_field=6'd53; 6'd50:zz_field=6'd61; 6'd51:zz_field=6'd30;
                6'd52:zz_field=6'd7; 6'd53:zz_field=6'd15; 6'd54:zz_field=6'd38; 6'd55:zz_field=6'd46;
                6'd56:zz_field=6'd54; 6'd57:zz_field=6'd62; 6'd58:zz_field=6'd23; 6'd59:zz_field=6'd31;
                6'd60:zz_field=6'd39; 6'd61:zz_field=6'd47; 6'd62:zz_field=6'd55; default:zz_field=6'd63;
            endcase
        end
    endfunction

    integer i;
    reg signed [QW-1:0] val;
    reg [5:0] pos;
    reg [6:0] tc;
    reg [5:0] last;
    reg [1:0] t1;
    reg done_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0; done_pending <= 1'b0; scan_flat <= {(64*QW){1'b0}}; total_coeffs <= 7'd0; trailing_ones <= 2'd0; last_nonzero_idx <= 6'd0;
        end else begin
            done <= done_pending;
            done_pending <= start;
            if (start) begin
                tc = 7'd0; last = 6'd0; t1 = 2'd0;
                for (i = 0; i < 64; i = i + 1) begin
                    pos = field_scan ? zz_field(i[5:0]) : zz_frame(i[5:0]);
                    val = $signed(in_flat[pos*QW +: QW]);
                    scan_flat[i*QW +: QW] <= val;
                    if (val != 0) begin tc = tc + 7'd1; last = i[5:0]; end
                end
                if (tc != 0) begin
                    for (i = 63; i >= 0; i = i - 1) begin
                        if (i <= last && t1 < 2'd3) begin
                            pos = field_scan ? zz_field(i[5:0]) : zz_frame(i[5:0]);
                            val = $signed(in_flat[pos*QW +: QW]);
                            if (val == 1 || val == -1) t1 = t1 + 2'd1;
                            else if (val != 0) i = -1;
                        end
                    end
                end
                total_coeffs <= tc;
                trailing_ones <= t1;
                last_nonzero_idx <= last;
            end
        end
    end
endmodule
