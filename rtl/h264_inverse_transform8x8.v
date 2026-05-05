// h264_inverse_transform8x8.v — standalone H.264 8x8 inverse transform.
// IDCT butterfly derived from H.264 8x8 inverse transform and x264 common/dct.c IDCT8_1D.

module h264_inverse_transform8x8 #(
    parameter BIT_DEPTH = 8
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  done,
    input  wire [64*CW-1:0] in_flat,
    output reg  [1023:0] out_flat
);
    localparam CW = BIT_DEPTH + 14;
    localparam IW = CW + 4;

    reg signed [IW-1:0] in_mem [0:63];
    reg signed [IW-1:0] col_mem [0:63];
    reg signed [IW-1:0] out_mem [0:63];
    reg done_pending;

    task idct1d;
        input signed [IW-1:0] x0, x1, x2, x3, x4, x5, x6, x7;
        output signed [IW-1:0] y0, y1, y2, y3, y4, y5, y6, y7;
        reg signed [IW-1:0] a0, a1, a2, a3, a4, a5, a6, a7;
        reg signed [IW-1:0] b0, b1, b2, b3, b4, b5, b6, b7;
        begin
            a0 = x0 + x4; a2 = x0 - x4; a4 = (x2 >>> 1) - x6; a6 = (x6 >>> 1) + x2;
            b0 = a0 + a6; b2 = a2 + a4; b4 = a2 - a4; b6 = a0 - a6;
            a1 = -x3 + x5 - x7 - (x7 >>> 1);
            a3 =  x1 + x7 - x3 - (x3 >>> 1);
            a5 = -x1 + x7 + x5 + (x5 >>> 1);
            a7 =  x3 + x5 + x1 + (x1 >>> 1);
            b1 = (a7 >>> 2) + a1;
            b3 = a3 + (a5 >>> 2);
            b5 = (a3 >>> 2) - a5;
            b7 = a7 - (a1 >>> 2);
            y0 = b0 + b7; y1 = b2 + b5; y2 = b4 + b3; y3 = b6 + b1;
            y4 = b6 - b1; y5 = b4 - b3; y6 = b2 - b5; y7 = b0 - b7;
        end
    endtask

    integer i, r, c;
    always @* begin
        for (i = 0; i < 64; i = i + 1)
            in_mem[i] = {{(IW-CW){in_flat[i*CW+CW-1]}}, in_flat[i*CW +: CW]};
        for (c = 0; c < 8; c = c + 1)
            idct1d(in_mem[0*8+c], in_mem[1*8+c], in_mem[2*8+c], in_mem[3*8+c],
                   in_mem[4*8+c], in_mem[5*8+c], in_mem[6*8+c], in_mem[7*8+c],
                   col_mem[0*8+c], col_mem[1*8+c], col_mem[2*8+c], col_mem[3*8+c],
                   col_mem[4*8+c], col_mem[5*8+c], col_mem[6*8+c], col_mem[7*8+c]);
        for (r = 0; r < 8; r = r + 1) begin
            idct1d(col_mem[r*8+0], col_mem[r*8+1], col_mem[r*8+2], col_mem[r*8+3],
                   col_mem[r*8+4], col_mem[r*8+5], col_mem[r*8+6], col_mem[r*8+7],
                   out_mem[r*8+0], out_mem[r*8+1], out_mem[r*8+2], out_mem[r*8+3],
                   out_mem[r*8+4], out_mem[r*8+5], out_mem[r*8+6], out_mem[r*8+7]);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            done_pending <= 1'b0;
            out_flat <= 1024'd0;
        end else begin
            done <= done_pending;
            done_pending <= start;
            if (start) begin
                for (i = 0; i < 64; i = i + 1)
                    out_flat[i*16 +: 16] <= (out_mem[i] + {{(IW-6){1'b0}}, 6'd32}) >>> 6;
            end
        end
    end
endmodule
