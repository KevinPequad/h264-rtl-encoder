// h264_transform.v — Forward 4x4 Integer DCT
// H.264 forward transform: Y = Cf * X * Cf'
// Processes one 4x4 block at a time.
// Input/output are flattened 16-element arrays.

module h264_transform (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Input: 4x4 signed residual block (row-major, 9 bits each, 144 bits total)
    input  wire [143:0] in_flat,

    // Output: 4x4 signed transform coefficients (16 bits each, 256 bits total)
    output reg  [255:0] out_flat
);

    reg [2:0] state;
    localparam S_IDLE  = 3'd0;
    localparam S_ROW   = 3'd1;
    localparam S_COL   = 3'd2;
    localparam S_DONE  = 3'd3;

    reg signed [15:0] tmp [0:15]; // intermediate row-transform results
    reg [1:0] step;

    // Extract signed 9-bit input, sign-extend to 16 bits
    wire signed [15:0] inp [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack_in
            assign inp[gi] = {{7{in_flat[gi*9+8]}}, in_flat[gi*9 +: 9]};
        end
    endgenerate

    // Row transform wires
    reg signed [15:0] ra, rb, rc, rd;
    reg signed [15:0] rp, rq, rr, rs;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 1'b0;
            step  <= 2'd0;
            out_flat <= 256'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_ROW;
                        step  <= 2'd0;
                    end
                end

                // verilator lint_off BLKSEQ
                S_ROW: begin
                    ra = inp[{step, 2'd0}];
                    rb = inp[{step, 2'd1}];
                    rc = inp[{step, 2'd2}];
                    rd = inp[{step, 2'd3}];

                    rp = ra + rb + rc + rd;
                    rq = (ra <<< 1) + rb - rc - (rd <<< 1);
                    rr = ra - rb - rc + rd;
                    rs = ra - (rb <<< 1) + (rc <<< 1) - rd;
                // verilator lint_on BLKSEQ

                    tmp[{step, 2'd0}] <= rp;
                    tmp[{step, 2'd1}] <= rq;
                    tmp[{step, 2'd2}] <= rr;
                    tmp[{step, 2'd3}] <= rs;

                    if (step == 2'd3) begin
                        step  <= 2'd0;
                        state <= S_COL;
                    end else begin
                        step <= step + 2'd1;
                    end
                end

                // verilator lint_off BLKSEQ
                S_COL: begin
                    ra = tmp[{2'd0, step}];
                    rb = tmp[{2'd1, step}];
                    rc = tmp[{2'd2, step}];
                    rd = tmp[{2'd3, step}];

                    rp = ra + rb + rc + rd;
                    rq = (ra <<< 1) + rb - rc - (rd <<< 1);
                    rr = ra - rb - rc + rd;
                    rs = ra - (rb <<< 1) + (rc <<< 1) - rd;
                // verilator lint_on BLKSEQ

                    out_flat[{2'd0, step}*16 +: 16] <= rp;
                    out_flat[{2'd1, step}*16 +: 16] <= rq;
                    out_flat[{2'd2, step}*16 +: 16] <= rr;
                    out_flat[{2'd3, step}*16 +: 16] <= rs;

                    if (step == 2'd3) begin
                        state <= S_DONE;
                    end else begin
                        step <= step + 2'd1;
                    end
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
