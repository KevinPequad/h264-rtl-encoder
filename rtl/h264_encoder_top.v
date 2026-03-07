// h264_encoder_top.v — Top-Level H.264 Intra-Only Encoder
// Baseline profile, CAVLC, 320x176 (20x11 MBs), QP=26, DC-only intra prediction
// Processes one YUV420 frame in raster macroblock order.
// Pipeline: fetch → (predict → transform → quant → zigzag → cavlc →
//            inverse_quant → inverse_transform → reconstruct) per sub-block
// Then: bitstream output with SPS/PPS/slice header/trailing bits.

module h264_encoder_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,

    // Raw frame memory read port (YUV420 planar)
    output wire [19:0] raw_mem_addr,
    input  wire [7:0]  raw_mem_data,

    // Bitstream memory write port
    output wire [23:0] bs_mem_addr,
    output wire [7:0]  bs_mem_data,
    output wire        bs_mem_wr,
    output wire [23:0] bs_bytes_written
);

    // ====================================================================
    // Parameters
    // ====================================================================
    parameter FRAME_WIDTH  = 320;
    parameter FRAME_HEIGHT = 176;
    parameter MB_COLS      = 20;
    parameter MB_ROWS      = 11;

    localparam [19:0] FRAME_Y_BASE  = 20'd0;
    localparam [19:0] FRAME_CB_BASE = FRAME_WIDTH * FRAME_HEIGHT;
    localparam [19:0] FRAME_CR_BASE = FRAME_CB_BASE + (FRAME_WIDTH * FRAME_HEIGHT / 4);

    // ====================================================================
    // Top-level FSM
    // ====================================================================
    localparam TS_IDLE         = 4'd0;
    localparam TS_WRITE_SPS    = 4'd1;
    localparam TS_WAIT_SPS     = 4'd2;
    localparam TS_WRITE_PPS    = 4'd3;
    localparam TS_WAIT_PPS     = 4'd4;
    localparam TS_WRITE_SLICE  = 4'd5;
    localparam TS_WAIT_SLICE   = 4'd6;
    localparam TS_FETCH_MB     = 4'd7;
    localparam TS_WAIT_FETCH   = 4'd8;
    localparam TS_MB_HDR       = 4'd9;
    localparam TS_ENCODE_SBLK  = 4'd10;
    localparam TS_NEXT_MB      = 4'd11;
    localparam TS_TRAILING     = 4'd12;
    localparam TS_DONE         = 4'd13;

    reg [3:0]  top_state;
    reg [4:0]  mb_x;
    reg [3:0]  mb_y;
    reg [3:0]  sub_blk;
    reg [7:0]  mb_count;

    // Sub-block processing stages
    localparam BS_PRED     = 3'd0;
    localparam BS_XFORM    = 3'd1;
    localparam BS_QUANT    = 3'd2;
    localparam BS_ZIGZAG   = 3'd3;
    localparam BS_CAVLC    = 3'd4;
    localparam BS_IQ       = 3'd5;
    localparam BS_IT       = 3'd6;
    localparam BS_RECON    = 3'd7;
    reg [2:0]  blk_state;
    reg        blk_started;
    reg        iq_done_latched;

    // ====================================================================
    // Inter-module wires
    // ====================================================================

    // Fetch
    reg         fetch_start;
    wire        fetch_done;
    wire [2047:0] fetched_luma;
    /* verilator lint_off UNUSED */
    wire [511:0]  fetched_cb;
    wire [511:0]  fetched_cr;
    /* verilator lint_on UNUSED */

    // Intra prediction
    reg         pred_start;
    wire        pred_done;
    reg         sb_top_avail, sb_left_avail;
    reg [31:0]  sb_top_pixels;
    reg [31:0]  sb_left_pixels;
    reg [127:0] sb_orig_pixels;
    wire [127:0] pred_4x4_w;
    wire [143:0] resid_4x4_w;

    // Transform
    reg         xform_start;
    wire        xform_done;
    wire [255:0] xform_out_flat;

    // Quantize
    reg         quant_start;
    wire        quant_done;
    wire [255:0] quant_out_flat;

    // Zigzag
    reg         zz_start;
    wire        zz_done;
    wire [255:0] scan_flat;
    wire [4:0]   total_coeffs;
    wire [1:0]   trailing_ones;
    wire [3:0]   last_nonzero_idx;

    // CAVLC
    reg         cavlc_start;
    wire        cavlc_done;
    wire [31:0] cavlc_bits;
    wire [5:0]  cavlc_count;
    wire        cavlc_bits_valid;

    // Inverse quant
    reg         iq_start;
    wire        iq_done;
    wire [255:0] iq_out_flat;

    // Inverse transform
    reg         it_start;
    wire        it_done;
    wire [255:0] it_out_flat;

    // Reconstruct
    reg         recon_start;
    wire        recon_done;
    reg  [2047:0] recon_buf;
    wire [2047:0] recon_out_w;
    wire [127:0]  recon_top_row_w;
    wire [127:0]  recon_right_col_w;

    // Bitstream writer
    reg         bs_cmd_sps, bs_cmd_pps, bs_cmd_slice, bs_cmd_mb_hdr, bs_cmd_trailing, bs_cmd_flush;
    wire        bs_busy, bs_cmd_done;
    reg         mb_has_residual;

    // Neighbor storage
    reg [2559:0] top_ref_flat;
    reg [127:0]  left_ref_flat;
    reg [127:0]  top_pixels_flat, left_pixels_flat;
    reg          mb_top_avail, mb_left_avail;

    // Trailing/flush sequencing
    reg flush_pending, flush_accepted;

    // ====================================================================
    // Mapping and Buffer Extraction
    // ====================================================================
    wire [1:0] sb_r = {sub_blk[3], sub_blk[1]};
    wire [1:0] sb_c = {sub_blk[2], sub_blk[0]};

    reg [2047:0] pred_buf;

    integer idx_ei, idx_pi;
    always @(*) begin
        // Sub-block original pixels
        sb_orig_pixels = 128'd0;
        for (idx_ei = 0; idx_ei < 16; idx_ei = idx_ei + 1) begin
            sb_orig_pixels[idx_ei*8 +: 8] = fetched_luma[( ({sb_r, idx_ei[3:2]} << 4) | {sb_c, idx_ei[1:0]} )*8 +: 8];
        end

        // Sub-block prediction pixels
        pred_buf = 2048'd0;
        for (idx_pi = 0; idx_pi < 16; idx_pi = idx_pi + 1) begin
            pred_buf[( ({sb_r, idx_pi[3:2]} << 4) | {sb_c, idx_pi[1:0]} )*8 +: 8] = pred_4x4_w[idx_pi*8 +: 8];
        end

        // Neighbor routing
        if (sb_r == 2'd0) begin
            sb_top_avail  = mb_top_avail;
            sb_top_pixels = top_pixels_flat[sb_c*32 +: 32];
        end else begin
            sb_top_avail  = 1'b1;
            sb_top_pixels = recon_buf[((sb_r*4 - 1)*16 + sb_c*4)*8 +: 32];
        end

        if (sb_c == 2'd0) begin
            sb_left_avail  = mb_left_avail;
            sb_left_pixels = left_pixels_flat[sb_r*32 +: 32];
        end else begin
            sb_left_avail  = 1'b1;
            sb_left_pixels[7:0]   = recon_buf[((sb_r*4 + 0)*16 + (sb_c*4 - 1))*8 +: 8];
            sb_left_pixels[15:8]  = recon_buf[((sb_r*4 + 1)*16 + (sb_c*4 - 1))*8 +: 8];
            sb_left_pixels[23:16] = recon_buf[((sb_r*4 + 2)*16 + (sb_c*4 - 1))*8 +: 8];
            sb_left_pixels[31:24] = recon_buf[((sb_r*4 + 3)*16 + (sb_c*4 - 1))*8 +: 8];
        end
    end

    // ====================================================================
    // Module instantiations
    // ====================================================================

    h264_fetch u_fetch (
        .clk(clk), .rst_n(rst_n), .start(fetch_start), .frame_base_y(FRAME_Y_BASE),
        .frame_base_cb(FRAME_CB_BASE), .frame_base_cr(FRAME_CR_BASE), .mb_x(mb_x), .mb_y(mb_y),
        .frame_width(FRAME_WIDTH[9:0]), .raw_mem_addr(raw_mem_addr), .raw_mem_data(raw_mem_data),
        .luma_flat(fetched_luma), .cb_flat(fetched_cb), .cr_flat(fetched_cr), .done(fetch_done), .valid()
    );

    h264_intra_pred u_pred (
        .clk(clk), .rst_n(rst_n), .start(pred_start), .done(pred_done), .top_avail(sb_top_avail), .left_avail(sb_left_avail),
        .orig_4x4(sb_orig_pixels), .top_4(sb_top_pixels), .left_4(sb_left_pixels), .pred_4x4(pred_4x4_w), .resid_4x4(resid_4x4_w)
    );

    h264_transform u_xform (.clk(clk), .rst_n(rst_n), .start(xform_start), .done(xform_done), .in_flat(resid_4x4_w), .out_flat(xform_out_flat));
    h264_quantize u_quant (.clk(clk), .rst_n(rst_n), .start(quant_start), .done(quant_done), .in_flat(xform_out_flat), .quant_flat(quant_out_flat));
    h264_zigzag u_zigzag (.clk(clk), .rst_n(rst_n), .start(zz_start), .done(zz_done), .in_flat(quant_out_flat), .scan_flat(scan_flat), .total_coeffs(total_coeffs), .trailing_ones(trailing_ones), .last_nonzero_idx(last_nonzero_idx));

    reg [4:0] nz_coeff [0:15];
    reg [4:0] left_mb_nz [0:3];
    reg [4:0] top_mb_nz [0:79];

    reg [3:0] left_blk_idx, top_blk_idx;
    always @(*) begin
        case (sub_blk)
            4'd1:  left_blk_idx = 4'd0;  4'd3:  left_blk_idx = 4'd2;  4'd5:  left_blk_idx = 4'd4;
            4'd7:  left_blk_idx = 4'd6;  4'd9:  left_blk_idx = 4'd8;  4'd11: left_blk_idx = 4'd10;
            4'd13: left_blk_idx = 4'd12; 4'd15: left_blk_idx = 4'd14; 4'd4:  left_blk_idx = 4'd1;
            4'd6:  left_blk_idx = 4'd3;  4'd12: left_blk_idx = 4'd9;  4'd14: left_blk_idx = 4'd11;
            default: left_blk_idx = 4'd0;
        endcase
        case (sub_blk)
            4'd2:  top_blk_idx = 4'd0;   4'd3:  top_blk_idx = 4'd1;   4'd6:  top_blk_idx = 4'd4;
            4'd7:  top_blk_idx = 4'd5;   4'd10: top_blk_idx = 4'd8;   4'd11: top_blk_idx = 4'd9;
            4'd14: top_blk_idx = 4'd12;  4'd15: top_blk_idx = 4'd13;  4'd8:  top_blk_idx = 4'd2;
            4'd9:  top_blk_idx = 4'd3;   4'd12: top_blk_idx = 4'd6;   4'd13: top_blk_idx = 4'd7;
            default: top_blk_idx = 4'd0;
        endcase
    end

    wire [4:0] nA_val = (sb_c > 0) ? nz_coeff[left_blk_idx] : (mb_left_avail ? left_mb_nz[sb_r] : 5'd0);
    wire [4:0] nB_val = (sb_r > 0) ? nz_coeff[top_blk_idx]  : (mb_top_avail  ? top_mb_nz[mb_x * 4 + sb_c] : 5'd0);
    reg [3:0] nC_val;
    always @(*) begin
        if (((sb_c > 0) || mb_left_avail) && ((sb_r > 0) || mb_top_avail))
            nC_val = (nA_val[3:0] + nB_val[3:0] + 4'd1) >> 1;
        else if ((sb_c > 0) || mb_left_avail)
            nC_val = nA_val[3:0];
        else if ((sb_r > 0) || mb_top_avail)
            nC_val = nB_val[3:0];
        else
            nC_val = 4'd0;
    end

    h264_cavlc u_cavlc (.clk(clk), .rst_n(rst_n), .start(cavlc_start), .done(cavlc_done), .scan_flat(scan_flat), .total_coeffs(total_coeffs), .trailing_ones(trailing_ones), .last_nonzero_idx(last_nonzero_idx), .nC(nC_val), .bits_out(cavlc_bits), .bits_count(cavlc_count), .bits_valid(cavlc_bits_valid));
    h264_inverse_quant u_iq (.clk(clk), .rst_n(rst_n), .start(iq_start), .done(iq_done), .quant_flat(quant_out_flat), .dequant_flat(iq_out_flat));
    h264_inverse_transform u_it (.clk(clk), .rst_n(rst_n), .start(it_start), .done(it_done), .in_flat(iq_out_flat), .out_flat(it_out_flat));

    h264_reconstruct u_recon (
        .clk(clk), .rst_n(rst_n), .start(recon_start), .done(recon_done), .sub_block_idx(sub_blk),
        .pred_flat(pred_buf), .recon_resid_flat(it_out_flat), .recon_in(recon_buf), .recon_out(recon_out_w),
        .recon_top_row(recon_top_row_w), .recon_right_col(recon_right_col_w)
    );

    h264_bitstream u_bitstream (
        .clk(clk), .rst_n(rst_n), .cmd_write_sps(bs_cmd_sps), .cmd_write_pps(bs_cmd_pps), .cmd_write_slice_hdr(bs_cmd_slice),
        .cmd_write_mb_header(bs_cmd_mb_hdr), .cmd_write_trailing(bs_cmd_trailing), .cmd_flush(bs_cmd_flush),
        .cavlc_valid(cavlc_bits_valid), .cavlc_bits(cavlc_bits), .cavlc_count(cavlc_count),
        .mb_qp_delta(8'd0), .mb_has_residual(mb_has_residual), .busy(bs_busy), .cmd_done(bs_cmd_done),
        .bs_mem_addr(bs_mem_addr), .bs_mem_data(bs_mem_data), .bs_mem_wr(bs_mem_wr), .bs_bytes_written(bs_bytes_written)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_state <= TS_IDLE; done <= 1'b0; mb_x <= 5'd0; mb_y <= 4'd0; sub_blk <= 4'd0; mb_count <= 8'd0;
            fetch_start <= 1'b0; pred_start <= 1'b0; xform_start <= 1'b0; quant_start <= 1'b0; zz_start <= 1'b0;
            cavlc_start <= 1'b0; iq_start <= 1'b0; it_start <= 1'b0; recon_start <= 1'b0;
            bs_cmd_sps <= 1'b0; bs_cmd_pps <= 1'b0; bs_cmd_slice <= 1'b0; bs_cmd_mb_hdr <= 1'b0; bs_cmd_trailing <= 1'b0; bs_cmd_flush <= 1'b0;
            mb_top_avail <= 1'b0; mb_left_avail <= 1'b0; mb_has_residual <= 1'b0;
            blk_state <= BS_PRED; blk_started <= 1'b0; iq_done_latched <= 1'b0;
            recon_buf <= 2048'd0; top_ref_flat <= 2560'd0; left_ref_flat <= 128'd0;
            top_pixels_flat <= 128'd0; left_pixels_flat <= 128'd0; flush_pending <= 1'b0; flush_accepted <= 1'b0;
        end else begin
            fetch_start <= 1'b0; pred_start <= 1'b0; xform_start <= 1'b0; quant_start <= 1'b0; zz_start <= 1'b0;
            cavlc_start <= 1'b0; iq_start <= 1'b0; it_start <= 1'b0; recon_start <= 1'b0;
            bs_cmd_sps <= 1'b0; bs_cmd_pps <= 1'b0; bs_cmd_slice <= 1'b0; bs_cmd_mb_hdr <= 1'b0; bs_cmd_trailing <= 1'b0; bs_cmd_flush <= 1'b0;
            done <= 1'b0;

            case (top_state)
                TS_IDLE: if (start) begin top_state <= TS_WRITE_SPS; mb_x <= 5'd0; mb_y <= 4'd0; mb_count <= 8'd0; end
                TS_WRITE_SPS: begin bs_cmd_sps <= 1'b1; top_state <= TS_WAIT_SPS; end
                TS_WAIT_SPS: if (bs_cmd_done) top_state <= TS_WRITE_PPS;
                TS_WRITE_PPS: begin bs_cmd_pps <= 1'b1; top_state <= TS_WAIT_PPS; end
                TS_WAIT_PPS: if (bs_cmd_done) top_state <= TS_WRITE_SLICE;
                TS_WRITE_SLICE: begin bs_cmd_slice <= 1'b1; top_state <= TS_WAIT_SLICE; end
                TS_WAIT_SLICE: if (bs_cmd_done) top_state <= TS_FETCH_MB;
                TS_FETCH_MB: begin
                    fetch_start <= 1'b1; mb_top_avail <= (mb_y > 4'd0); mb_left_avail <= (mb_x > 5'd0);
                    top_pixels_flat <= top_ref_flat[mb_x * 128 +: 128]; left_pixels_flat <= left_ref_flat;
                    top_state <= TS_WAIT_FETCH;
                end
                TS_WAIT_FETCH: if (fetch_done) top_state <= TS_MB_HDR;
                TS_MB_HDR: if (!bs_busy) begin
                    mb_has_residual <= 1'b1; bs_cmd_mb_hdr <= 1'b1; sub_blk <= 4'd0;
                    blk_state <= BS_PRED; blk_started <= 1'b0; recon_buf <= 2048'd0; top_state <= TS_ENCODE_SBLK;
                end
                TS_ENCODE_SBLK: begin
                    case (blk_state)
                        BS_PRED:   if (!blk_started) begin pred_start <= 1'b1; blk_started <= 1'b1; end else if (pred_done) begin blk_state <= BS_XFORM; blk_started <= 1'b0; end
                        BS_XFORM:  if (!blk_started) begin xform_start <= 1'b1; blk_started <= 1'b1; end else if (xform_done) begin blk_state <= BS_QUANT; blk_started <= 1'b0; end
                        BS_QUANT:  if (!blk_started) begin quant_start <= 1'b1; blk_started <= 1'b1; end else if (quant_done) begin blk_state <= BS_ZIGZAG; blk_started <= 1'b0; end
                        BS_ZIGZAG: if (!blk_started) begin zz_start <= 1'b1; iq_start <= 1'b1; blk_started <= 1'b1; iq_done_latched <= 1'b0; end 
                                   else begin if (iq_done) iq_done_latched <= 1'b1; if (zz_done) begin nz_coeff[sub_blk] <= total_coeffs; blk_state <= BS_CAVLC; blk_started <= 1'b0; end end
                        BS_CAVLC:  if (!blk_started && !bs_busy) begin cavlc_start <= 1'b1; blk_started <= 1'b1; end 
                                   else begin if (iq_done) iq_done_latched <= 1'b1; if (cavlc_done) begin blk_state <= BS_IQ; blk_started <= 1'b0; end end
                        BS_IQ:     if (iq_done || iq_done_latched) begin blk_state <= BS_IT; blk_started <= 1'b0; end else if (iq_done) iq_done_latched <= 1'b1;
                        BS_IT:     if (!blk_started) begin it_start <= 1'b1; blk_started <= 1'b1; end else if (it_done) begin blk_state <= BS_RECON; blk_started <= 1'b0; end
                        BS_RECON:  if (!blk_started) begin recon_start <= 1'b1; blk_started <= 1'b1; end 
                                   else if (recon_done) begin recon_buf <= recon_out_w; if (sub_blk == 4'd15) top_state <= TS_NEXT_MB; else begin sub_blk <= sub_blk + 4'd1; blk_state <= BS_PRED; blk_started <= 1'b0; end end
                        default:   blk_state <= BS_PRED;
                    endcase
                end
                TS_NEXT_MB: begin
                    left_mb_nz[0] <= nz_coeff[5]; left_mb_nz[1] <= nz_coeff[7]; left_mb_nz[2] <= nz_coeff[13]; left_mb_nz[3] <= nz_coeff[15];
                    top_mb_nz[mb_x * 4 + 0] <= nz_coeff[10]; top_mb_nz[mb_x * 4 + 1] <= nz_coeff[11]; top_mb_nz[mb_x * 4 + 2] <= nz_coeff[14]; top_mb_nz[mb_x * 4 + 3] <= nz_coeff[15];
                    top_ref_flat[mb_x * 128 +: 128] <= recon_top_row_w; left_ref_flat <= recon_right_col_w; mb_count <= mb_count + 8'd1;
                    if (mb_x == MB_COLS[4:0] - 5'd1) begin mb_x <= 5'd0; if (mb_y == MB_ROWS[3:0] - 4'd1) top_state <= TS_TRAILING; else begin mb_y <= mb_y + 4'd1; top_state <= TS_FETCH_MB; end end
                    else begin mb_x <= mb_x + 5'd1; top_state <= TS_FETCH_MB; end
                end
                TS_TRAILING: if (!bs_busy) begin bs_cmd_trailing <= 1'b1; flush_pending <= 1'b0; flush_accepted <= 1'b0; top_state <= TS_DONE; end
                TS_DONE: if (!flush_pending) begin if (bs_cmd_done) begin bs_cmd_flush <= 1'b1; flush_pending <= 1'b1; end end
                         else if (!flush_accepted) flush_accepted <= 1'b1;
                         else if (bs_cmd_done) begin done <= 1'b1; top_state <= TS_IDLE; end
                default: top_state <= TS_IDLE;
            endcase
        end
    end
endmodule
