// h264_deblock_edge.v -- one H.264 luma/chroma deblocking edge sample lane.
// Input order is p3,p2,p1,p0 | q0,q1,q2,q3 around the edge. Outputs expose
// the samples that may change (p2,p1,p0,q0,q1,q2); p3/q3 are never modified.

module h264_deblock_edge #(
    parameter BIT_DEPTH = 8
) (
    input  wire [2:0] bs,
    input  wire       chroma_edge,
    input  wire [BIT_DEPTH-1:0] p3,
    input  wire [BIT_DEPTH-1:0] p2,
    input  wire [BIT_DEPTH-1:0] p1,
    input  wire [BIT_DEPTH-1:0] p0,
    input  wire [BIT_DEPTH-1:0] q0,
    input  wire [BIT_DEPTH-1:0] q1,
    input  wire [BIT_DEPTH-1:0] q2,
    input  wire [BIT_DEPTH-1:0] q3,
    input  wire [BIT_DEPTH:0] alpha,
    input  wire [BIT_DEPTH:0] beta,
    input  wire signed [BIT_DEPTH:0] tc0,
    output reg  [BIT_DEPTH-1:0] p2_out,
    output reg  [BIT_DEPTH-1:0] p1_out,
    output reg  [BIT_DEPTH-1:0] p0_out,
    output reg  [BIT_DEPTH-1:0] q0_out,
    output reg  [BIT_DEPTH-1:0] q1_out,
    output reg  [BIT_DEPTH-1:0] q2_out
);
    function automatic integer abs_i;
        input integer v;
        begin
            abs_i = (v < 0) ? -v : v;
        end
    endfunction

    function automatic integer clip3_i;
        input integer v;
        input integer lo;
        input integer hi;
        begin
            if (v < lo)
                clip3_i = lo;
            else if (v > hi)
                clip3_i = hi;
            else
                clip3_i = v;
        end
    endfunction

    function automatic [BIT_DEPTH-1:0] clip1;
        input integer v;
        integer maxv;
        begin
            maxv = (1 << BIT_DEPTH) - 1;
            if (v < 0)
                clip1 = {BIT_DEPTH{1'b0}};
            else if (v > maxv)
                clip1 = maxv[BIT_DEPTH-1:0];
            else
                clip1 = v[BIT_DEPTH-1:0];
        end
    endfunction

    integer p3_i;
    integer p2_i;
    integer p1_i;
    integer p0_i;
    integer q0_i;
    integer q1_i;
    integer q2_i;
    integer q3_i;
    integer alpha_i;
    integer beta_i;
    integer tc0_i;
    integer tc_i;
    integer delta_i;
    integer mid_i;

    always @(*) begin
        p3_i = p3;
        p2_i = p2;
        p1_i = p1;
        p0_i = p0;
        q0_i = q0;
        q1_i = q1;
        q2_i = q2;
        q3_i = q3;
        alpha_i = alpha;
        beta_i = beta;
        tc0_i = tc0;
        tc_i = 0;
        delta_i = 0;
        mid_i = 0;

        p2_out = p2;
        p1_out = p1;
        p0_out = p0;
        q0_out = q0;
        q1_out = q1;
        q2_out = q2;

        if ((bs != 3'd0) &&
            (abs_i(p0_i - q0_i) < alpha_i) &&
            (abs_i(p1_i - p0_i) < beta_i) &&
            (abs_i(q1_i - q0_i) < beta_i)) begin
            if (bs >= 3'd4) begin
                if (chroma_edge) begin
                    p0_out = clip1((2*p1_i + p0_i + q1_i + 2) >>> 2);
                    q0_out = clip1((2*q1_i + q0_i + p1_i + 2) >>> 2);
                end else if (abs_i(p0_i - q0_i) < ((alpha_i >>> 2) + 2)) begin
                    if (abs_i(p2_i - p0_i) < beta_i) begin
                        p0_out = clip1((p2_i + 2*p1_i + 2*p0_i + 2*q0_i + q1_i + 4) >>> 3);
                        p1_out = clip1((p2_i + p1_i + p0_i + q0_i + 2) >>> 2);
                        p2_out = clip1((2*p3_i + 3*p2_i + p1_i + p0_i + q0_i + 4) >>> 3);
                    end else begin
                        p0_out = clip1((2*p1_i + p0_i + q1_i + 2) >>> 2);
                    end
                    if (abs_i(q2_i - q0_i) < beta_i) begin
                        q0_out = clip1((p1_i + 2*p0_i + 2*q0_i + 2*q1_i + q2_i + 4) >>> 3);
                        q1_out = clip1((p0_i + q0_i + q1_i + q2_i + 2) >>> 2);
                        q2_out = clip1((2*q3_i + 3*q2_i + q1_i + q0_i + p0_i + 4) >>> 3);
                    end else begin
                        q0_out = clip1((2*q1_i + q0_i + p1_i + 2) >>> 2);
                    end
                end else begin
                    p0_out = clip1((2*p1_i + p0_i + q1_i + 2) >>> 2);
                    q0_out = clip1((2*q1_i + q0_i + p1_i + 2) >>> 2);
                end
            end else if (chroma_edge) begin
                if (tc0_i > 0) begin
                    delta_i = clip3_i((((q0_i - p0_i) * 4) + (p1_i - q1_i) + 4) >>> 3,
                                      -tc0_i, tc0_i);
                    p0_out = clip1(p0_i + delta_i);
                    q0_out = clip1(q0_i - delta_i);
                end
            end else begin
                tc_i = tc0_i;
                mid_i = (p0_i + q0_i + 1) >>> 1;
                if (abs_i(p2_i - p0_i) < beta_i) begin
                    if (tc0_i != 0)
                        p1_out = clip1(p1_i + clip3_i(((p2_i + mid_i) >>> 1) - p1_i, -tc0_i, tc0_i));
                    tc_i = tc_i + 1;
                end
                if (abs_i(q2_i - q0_i) < beta_i) begin
                    if (tc0_i != 0)
                        q1_out = clip1(q1_i + clip3_i(((q2_i + mid_i) >>> 1) - q1_i, -tc0_i, tc0_i));
                    tc_i = tc_i + 1;
                end
                delta_i = clip3_i((((q0_i - p0_i) * 4) + (p1_i - q1_i) + 4) >>> 3,
                                  -tc_i, tc_i);
                p0_out = clip1(p0_i + delta_i);
                q0_out = clip1(q0_i - delta_i);
            end
        end
    end
endmodule
