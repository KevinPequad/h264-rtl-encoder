// h264_inverse_transform.v — Inverse 4x4 Integer DCT
// H.264 inverse transform for reconstruction
// Column then row inverse butterfly with rounding: (result + 32) >> 6
// Butterfly:
//   e0 = a + c;  e1 = a - c
//   e2 = (b>>1) - d;  e3 = b + (d>>1)
//   out = [e0+e3, e1+e2, e1-e2, e0-e3]

module h264_inverse_transform #(
    parameter BIT_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Input: 4x4 dequantized coefficients (16 * CW-bit signed)
    input  wire [16*CW-1:0] in_flat,

    // Output: 4x4 reconstructed residual (16 * 16-bit signed)
    output reg  [255:0] out_flat
);

    localparam CW  = BIT_DEPTH + 8;
    localparam IW  = CW + 2; // intermediate width: adds headroom for butterfly sums

    reg [2:0] state;
    localparam S_IDLE = 3'd0;
    localparam S_COL  = 3'd1;
    localparam S_ROW  = 3'd2;
    localparam S_DONE = 3'd3;

    reg signed [IW-1:0] tmp [0:15];
    reg [1:0] step;

    reg signed [IW-1:0] a, b, c, d;
    reg signed [IW-1:0] e0, e1, e2, e3;

    // Unpack inputs: sign-extend CW-bit to IW-bit
    wire signed [CW-1:0] inp [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack
            assign inp[gi] = $signed(in_flat[gi*CW +: CW]);
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            done     <= 1'b0;
            step     <= 2'd0;
            out_flat <= 256'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_COL;
                        step  <= 2'd0;
                    end
                end

                // Column-wise inverse transform
                // verilator lint_off BLKSEQ
                S_COL: begin
                    a = {{(IW-CW){inp[{2'd0, step}][CW-1]}}, inp[{2'd0, step}]};
                    b = {{(IW-CW){inp[{2'd1, step}][CW-1]}}, inp[{2'd1, step}]};
                    c = {{(IW-CW){inp[{2'd2, step}][CW-1]}}, inp[{2'd2, step}]};
                    d = {{(IW-CW){inp[{2'd3, step}][CW-1]}}, inp[{2'd3, step}]};

                    e0 = a + c;
                    e1 = a - c;
                    e2 = (b >>> 1) - d;
                    e3 = b + (d >>> 1);
                // verilator lint_on BLKSEQ

                    tmp[{2'd0, step}] <= e0 + e3;
                    tmp[{2'd1, step}] <= e1 + e2;
                    tmp[{2'd2, step}] <= e1 - e2;
                    tmp[{2'd3, step}] <= e0 - e3;

                    if (step == 2'd3) begin
                        step  <= 2'd0;
                        state <= S_ROW;
                    end else begin
                        step <= step + 2'd1;
                    end
                end

                // Row-wise inverse transform with rounding
                // verilator lint_off BLKSEQ
                S_ROW: begin
                    a = tmp[{step, 2'd0}];
                    b = tmp[{step, 2'd1}];
                    c = tmp[{step, 2'd2}];
                    d = tmp[{step, 2'd3}];

                    e0 = a + c;
                    e1 = a - c;
                    e2 = (b >>> 1) - d;
                    e3 = b + (d >>> 1);
                // verilator lint_on BLKSEQ

                    out_flat[{step, 2'd0}*16 +: 16] <= (e0 + e3 + $signed({{(IW-6){1'b0}}, 6'd32})) >>> 6;
                    out_flat[{step, 2'd1}*16 +: 16] <= (e1 + e2 + $signed({{(IW-6){1'b0}}, 6'd32})) >>> 6;
                    out_flat[{step, 2'd2}*16 +: 16] <= (e1 - e2 + $signed({{(IW-6){1'b0}}, 6'd32})) >>> 6;
                    out_flat[{step, 2'd3}*16 +: 16] <= (e0 - e3 + $signed({{(IW-6){1'b0}}, 6'd32})) >>> 6;

                    if (step == 2'd3)
                        state <= S_DONE;
                    else
                        step <= step + 2'd1;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
