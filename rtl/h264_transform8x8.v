// h264_transform8x8.v — standalone H.264 8x8 forward transform.
// DCT butterfly derived from H.264 8x8 integer transform and x264 common/dct.c DCT8_1D.

module h264_transform8x8 #(
    parameter BIT_DEPTH = 8
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  done,
    input  wire [64*BD1-1:0] in_flat,
    output reg  [64*CW-1:0] out_flat
);
    localparam BD1 = BIT_DEPTH + 1;
    localparam CW  = BIT_DEPTH + 14;

    reg signed [CW-1:0] in_mem [0:63];
    reg signed [CW-1:0] row_mem [0:63];
    reg signed [CW-1:0] out_mem [0:63];
    reg done_pending;

    task dct1d;
        input signed [CW-1:0] x0, x1, x2, x3, x4, x5, x6, x7;
        output signed [CW-1:0] y0, y1, y2, y3, y4, y5, y6, y7;
        reg signed [CW-1:0] s07, s16, s25, s34, d07, d16, d25, d34;
        reg signed [CW-1:0] a0, a1, a2, a3, a4, a5, a6, a7;
        begin
            s07 = x0 + x7; s16 = x1 + x6; s25 = x2 + x5; s34 = x3 + x4;
            a0 = s07 + s34; a1 = s16 + s25; a2 = s07 - s34; a3 = s16 - s25;
            d07 = x0 - x7; d16 = x1 - x6; d25 = x2 - x5; d34 = x3 - x4;
            a4 = d16 + d25 + d07 + (d07 >>> 1);
            a5 = d07 - d34 - d25 - (d25 >>> 1);
            a6 = d07 + d34 - d16 - (d16 >>> 1);
            a7 = d16 - d25 + d34 + (d34 >>> 1);
            y0 = a0 + a1;
            y1 = a4 + (a7 >>> 2);
            y2 = a2 + (a3 >>> 1);
            y3 = a5 + (a6 >>> 2);
            y4 = a0 - a1;
            y5 = a6 - (a5 >>> 2);
            y6 = (a2 >>> 1) - a3;
            y7 = (a4 >>> 2) - a7;
        end
    endtask

    integer i, r, c;
    always @* begin
        for (i = 0; i < 64; i = i + 1)
            in_mem[i] = {{(CW-BD1){in_flat[i*BD1+BD1-1]}}, in_flat[i*BD1 +: BD1]};
        for (r = 0; r < 8; r = r + 1)
            dct1d(in_mem[r*8+0], in_mem[r*8+1], in_mem[r*8+2], in_mem[r*8+3],
                  in_mem[r*8+4], in_mem[r*8+5], in_mem[r*8+6], in_mem[r*8+7],
                  row_mem[r*8+0], row_mem[r*8+1], row_mem[r*8+2], row_mem[r*8+3],
                  row_mem[r*8+4], row_mem[r*8+5], row_mem[r*8+6], row_mem[r*8+7]);
        for (c = 0; c < 8; c = c + 1)
            dct1d(row_mem[0*8+c], row_mem[1*8+c], row_mem[2*8+c], row_mem[3*8+c],
                  row_mem[4*8+c], row_mem[5*8+c], row_mem[6*8+c], row_mem[7*8+c],
                  out_mem[0*8+c], out_mem[1*8+c], out_mem[2*8+c], out_mem[3*8+c],
                  out_mem[4*8+c], out_mem[5*8+c], out_mem[6*8+c], out_mem[7*8+c]);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            done_pending <= 1'b0;
            out_flat <= {(64*CW){1'b0}};
        end else begin
            done <= done_pending;
            done_pending <= start;
            if (start) begin
                for (i = 0; i < 64; i = i + 1)
                    out_flat[i*CW +: CW] <= out_mem[i];
            end
        end
    end
endmodule
