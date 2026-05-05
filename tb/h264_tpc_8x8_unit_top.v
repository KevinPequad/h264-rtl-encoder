// Simulation-only scalar loader/readback wrapper for standalone 8x8 TPC gates.
// Keeps the C++ oracle simple: scalar writes load 8x8 memories, scalar reads
// sample each DUT output.  The production RTL modules still expose flat busses.

module h264_tpc_8x8_unit_top #(
    parameter BIT_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clear,

    input  wire [5:0]  qp,
    input  wire        field_scan,

    input  wire [5:0]  wr_idx,
    input  wire signed [31:0] wr_residual,
    input  wire signed [31:0] wr_coeff,
    input  wire signed [31:0] wr_quant,
    input  wire        wr_residual_en,
    input  wire        wr_coeff_en,
    input  wire        wr_quant_en,

    input  wire        start_fwd,
    output wire        done_fwd,
    input  wire        start_inv,
    output wire        done_inv,
    input  wire        start_quant,
    output wire        done_quant,
    input  wire        start_dequant,
    output wire        done_dequant,
    input  wire        start_scan,
    output wire        done_scan,

    input  wire [5:0]  rd_idx,
    output wire signed [31:0] fwd_out,
    output wire signed [31:0] inv_out,
    output wire signed [31:0] quant_out,
    output wire signed [31:0] dequant_out,
    output wire signed [31:0] scan_out,
    output wire [6:0]  scan_total_coeffs,
    output wire [1:0]  scan_trailing_ones,
    output wire [5:0]  scan_last_nonzero_idx
);

    localparam BD1 = BIT_DEPTH + 1;
    localparam CW  = BIT_DEPTH + 14;
    localparam QW  = 32;

    reg signed [BD1-1:0] residual_mem [0:63];
    reg signed [CW-1:0]  coeff_mem    [0:63];
    reg signed [QW-1:0]  quant_mem    [0:63];

    wire [64*BD1-1:0] residual_flat;
    wire [64*CW-1:0]  coeff_flat;
    wire [64*QW-1:0]  quant_flat_in;

    wire [64*CW-1:0]  fwd_flat;
    wire [1023:0]     inv_flat;
    wire [64*QW-1:0]  quant_flat;
    wire [64*CW-1:0]  dequant_flat;
    wire [64*QW-1:0]  scan_flat;

    genvar gi;
    generate
        for (gi = 0; gi < 64; gi = gi + 1) begin : pack_io
            assign residual_flat[gi*BD1 +: BD1] = residual_mem[gi];
            assign coeff_flat[gi*CW +: CW]      = coeff_mem[gi];
            assign quant_flat_in[gi*QW +: QW]   = quant_mem[gi];
        end
    endgenerate

    integer ii;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ii = 0; ii < 64; ii = ii + 1) begin
                residual_mem[ii] <= {BD1{1'b0}};
                coeff_mem[ii]    <= {CW{1'b0}};
                quant_mem[ii]    <= {QW{1'b0}};
            end
        end else if (clear) begin
            for (ii = 0; ii < 64; ii = ii + 1) begin
                residual_mem[ii] <= {BD1{1'b0}};
                coeff_mem[ii]    <= {CW{1'b0}};
                quant_mem[ii]    <= {QW{1'b0}};
            end
        end else begin
            if (wr_residual_en)
                residual_mem[wr_idx] <= wr_residual[BD1-1:0];
            if (wr_coeff_en)
                coeff_mem[wr_idx] <= wr_coeff[CW-1:0];
            if (wr_quant_en)
                quant_mem[wr_idx] <= wr_quant[QW-1:0];
        end
    end

    h264_transform8x8 #(
        .BIT_DEPTH(BIT_DEPTH)
    ) u_fwd (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_fwd),
        .done(done_fwd),
        .in_flat(residual_flat),
        .out_flat(fwd_flat)
    );

    h264_inverse_transform8x8 #(
        .BIT_DEPTH(BIT_DEPTH)
    ) u_inv (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_inv),
        .done(done_inv),
        .in_flat(coeff_flat),
        .out_flat(inv_flat)
    );

    h264_quantize8x8 #(
        .BIT_DEPTH(BIT_DEPTH),
        .QW(QW)
    ) u_quant (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_quant),
        .done(done_quant),
        .qp(qp),
        .in_flat(coeff_flat),
        .quant_flat(quant_flat)
    );

    h264_inverse_quant8x8 #(
        .BIT_DEPTH(BIT_DEPTH),
        .QW(QW)
    ) u_dequant (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_dequant),
        .done(done_dequant),
        .qp(qp),
        .quant_flat(quant_flat_in),
        .dequant_flat(dequant_flat)
    );

    h264_zigzag8x8 #(
        .QW(QW)
    ) u_scan (
        .clk(clk),
        .rst_n(rst_n),
        .start(start_scan),
        .done(done_scan),
        .field_scan(field_scan),
        .in_flat(quant_flat_in),
        .scan_flat(scan_flat),
        .total_coeffs(scan_total_coeffs),
        .trailing_ones(scan_trailing_ones),
        .last_nonzero_idx(scan_last_nonzero_idx)
    );

    assign fwd_out     = {{(32-CW){fwd_flat[rd_idx*CW+CW-1]}}, fwd_flat[rd_idx*CW +: CW]};
    assign inv_out     = {{16{inv_flat[rd_idx*16+15]}}, inv_flat[rd_idx*16 +: 16]};
    assign quant_out   = quant_flat[rd_idx*QW +: QW];
    assign dequant_out = {{(32-CW){dequant_flat[rd_idx*CW+CW-1]}}, dequant_flat[rd_idx*CW +: CW]};
    assign scan_out    = scan_flat[rd_idx*QW +: QW];

endmodule
