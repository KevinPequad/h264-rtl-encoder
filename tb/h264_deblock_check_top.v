module h264_deblock_check_top #(
    parameter BIT_DEPTH = 8
) (
    input  wire [5:0] index_a,
    input  wire [5:0] index_b,
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
    output wire [BIT_DEPTH:0] alpha,
    output wire [BIT_DEPTH:0] beta,
    output wire signed [BIT_DEPTH:0] tc0,
    output wire [BIT_DEPTH-1:0] p2_out,
    output wire [BIT_DEPTH-1:0] p1_out,
    output wire [BIT_DEPTH-1:0] p0_out,
    output wire [BIT_DEPTH-1:0] q0_out,
    output wire [BIT_DEPTH-1:0] q1_out,
    output wire [BIT_DEPTH-1:0] q2_out
);

    h264_deblock_tables #(.BIT_DEPTH(BIT_DEPTH)) u_tables (
        .index_a(index_a),
        .index_b(index_b),
        .bs(bs),
        .chroma_edge(chroma_edge),
        .alpha(alpha),
        .beta(beta),
        .tc0(tc0)
    );

    h264_deblock_edge #(.BIT_DEPTH(BIT_DEPTH)) u_edge (
        .bs(bs),
        .chroma_edge(chroma_edge),
        .p3(p3), .p2(p2), .p1(p1), .p0(p0),
        .q0(q0), .q1(q1), .q2(q2), .q3(q3),
        .alpha(alpha), .beta(beta), .tc0(tc0),
        .p2_out(p2_out), .p1_out(p1_out), .p0_out(p0_out),
        .q0_out(q0_out), .q1_out(q1_out), .q2_out(q2_out)
    );
endmodule
