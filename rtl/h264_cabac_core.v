// h264_cabac_core.v - CABAC arithmetic coding core
//
// This module implements the core H.264 CABAC arithmetic coder for:
// - regular decision bins
// - bypass bins
// - terminate bins
//
// It does not yet select syntax contexts or binarize H.264 syntax elements.
// Instead, it provides the arithmetic engine that later syntax-specific
// front-ends can drive with explicit bins and context states.

module h264_cabac_core (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,

    input  wire         bin_valid,
    input  wire         bin_value,
    input  wire         bin_bypass,
    input  wire         bin_terminate,
    input  wire [6:0]   ctx_state_in,

    output wire         bin_ready,

    output reg          bits_valid,
    output reg  [127:0] bits_out,
    output reg  [7:0]   bits_count,
    output reg          bits_overflow,

    output reg          ctx_state_wr,
    output reg  [6:0]   ctx_state_out,

    output reg          done,
    output reg          active
);

    reg [7:0] range_lps_tab [0:63][0:3];
    reg [5:0] mps_state_tab [0:63];
    reg [5:0] lps_state_tab [0:63];

    reg [10:0] cod_i_low;
    reg [8:0]  cod_i_range;
    reg [7:0]  outstanding_count;

    integer idx;
    integer sub;

    initial begin
        range_lps_tab[ 0][0] = 8'd128; range_lps_tab[ 0][1] = 8'd176; range_lps_tab[ 0][2] = 8'd208; range_lps_tab[ 0][3] = 8'd240;
        range_lps_tab[ 1][0] = 8'd128; range_lps_tab[ 1][1] = 8'd167; range_lps_tab[ 1][2] = 8'd197; range_lps_tab[ 1][3] = 8'd227;
        range_lps_tab[ 2][0] = 8'd128; range_lps_tab[ 2][1] = 8'd158; range_lps_tab[ 2][2] = 8'd187; range_lps_tab[ 2][3] = 8'd216;
        range_lps_tab[ 3][0] = 8'd123; range_lps_tab[ 3][1] = 8'd150; range_lps_tab[ 3][2] = 8'd178; range_lps_tab[ 3][3] = 8'd205;
        range_lps_tab[ 4][0] = 8'd116; range_lps_tab[ 4][1] = 8'd142; range_lps_tab[ 4][2] = 8'd169; range_lps_tab[ 4][3] = 8'd195;
        range_lps_tab[ 5][0] = 8'd111; range_lps_tab[ 5][1] = 8'd135; range_lps_tab[ 5][2] = 8'd160; range_lps_tab[ 5][3] = 8'd185;
        range_lps_tab[ 6][0] = 8'd105; range_lps_tab[ 6][1] = 8'd128; range_lps_tab[ 6][2] = 8'd152; range_lps_tab[ 6][3] = 8'd175;
        range_lps_tab[ 7][0] = 8'd100; range_lps_tab[ 7][1] = 8'd122; range_lps_tab[ 7][2] = 8'd144; range_lps_tab[ 7][3] = 8'd166;
        range_lps_tab[ 8][0] = 8'd95;  range_lps_tab[ 8][1] = 8'd116; range_lps_tab[ 8][2] = 8'd137; range_lps_tab[ 8][3] = 8'd158;
        range_lps_tab[ 9][0] = 8'd90;  range_lps_tab[ 9][1] = 8'd110; range_lps_tab[ 9][2] = 8'd130; range_lps_tab[ 9][3] = 8'd150;
        range_lps_tab[10][0] = 8'd85;  range_lps_tab[10][1] = 8'd104; range_lps_tab[10][2] = 8'd123; range_lps_tab[10][3] = 8'd142;
        range_lps_tab[11][0] = 8'd81;  range_lps_tab[11][1] = 8'd99;  range_lps_tab[11][2] = 8'd117; range_lps_tab[11][3] = 8'd135;
        range_lps_tab[12][0] = 8'd77;  range_lps_tab[12][1] = 8'd94;  range_lps_tab[12][2] = 8'd111; range_lps_tab[12][3] = 8'd128;
        range_lps_tab[13][0] = 8'd73;  range_lps_tab[13][1] = 8'd89;  range_lps_tab[13][2] = 8'd105; range_lps_tab[13][3] = 8'd122;
        range_lps_tab[14][0] = 8'd69;  range_lps_tab[14][1] = 8'd85;  range_lps_tab[14][2] = 8'd100; range_lps_tab[14][3] = 8'd116;
        range_lps_tab[15][0] = 8'd66;  range_lps_tab[15][1] = 8'd80;  range_lps_tab[15][2] = 8'd95;  range_lps_tab[15][3] = 8'd110;
        range_lps_tab[16][0] = 8'd62;  range_lps_tab[16][1] = 8'd76;  range_lps_tab[16][2] = 8'd90;  range_lps_tab[16][3] = 8'd104;
        range_lps_tab[17][0] = 8'd59;  range_lps_tab[17][1] = 8'd72;  range_lps_tab[17][2] = 8'd86;  range_lps_tab[17][3] = 8'd99;
        range_lps_tab[18][0] = 8'd56;  range_lps_tab[18][1] = 8'd69;  range_lps_tab[18][2] = 8'd81;  range_lps_tab[18][3] = 8'd94;
        range_lps_tab[19][0] = 8'd53;  range_lps_tab[19][1] = 8'd65;  range_lps_tab[19][2] = 8'd77;  range_lps_tab[19][3] = 8'd89;
        range_lps_tab[20][0] = 8'd51;  range_lps_tab[20][1] = 8'd62;  range_lps_tab[20][2] = 8'd73;  range_lps_tab[20][3] = 8'd85;
        range_lps_tab[21][0] = 8'd48;  range_lps_tab[21][1] = 8'd59;  range_lps_tab[21][2] = 8'd69;  range_lps_tab[21][3] = 8'd80;
        range_lps_tab[22][0] = 8'd46;  range_lps_tab[22][1] = 8'd56;  range_lps_tab[22][2] = 8'd66;  range_lps_tab[22][3] = 8'd76;
        range_lps_tab[23][0] = 8'd43;  range_lps_tab[23][1] = 8'd53;  range_lps_tab[23][2] = 8'd63;  range_lps_tab[23][3] = 8'd72;
        range_lps_tab[24][0] = 8'd41;  range_lps_tab[24][1] = 8'd50;  range_lps_tab[24][2] = 8'd59;  range_lps_tab[24][3] = 8'd69;
        range_lps_tab[25][0] = 8'd39;  range_lps_tab[25][1] = 8'd48;  range_lps_tab[25][2] = 8'd56;  range_lps_tab[25][3] = 8'd65;
        range_lps_tab[26][0] = 8'd37;  range_lps_tab[26][1] = 8'd45;  range_lps_tab[26][2] = 8'd54;  range_lps_tab[26][3] = 8'd62;
        range_lps_tab[27][0] = 8'd35;  range_lps_tab[27][1] = 8'd43;  range_lps_tab[27][2] = 8'd51;  range_lps_tab[27][3] = 8'd59;
        range_lps_tab[28][0] = 8'd33;  range_lps_tab[28][1] = 8'd41;  range_lps_tab[28][2] = 8'd48;  range_lps_tab[28][3] = 8'd56;
        range_lps_tab[29][0] = 8'd32;  range_lps_tab[29][1] = 8'd39;  range_lps_tab[29][2] = 8'd46;  range_lps_tab[29][3] = 8'd53;
        range_lps_tab[30][0] = 8'd30;  range_lps_tab[30][1] = 8'd37;  range_lps_tab[30][2] = 8'd43;  range_lps_tab[30][3] = 8'd50;
        range_lps_tab[31][0] = 8'd29;  range_lps_tab[31][1] = 8'd35;  range_lps_tab[31][2] = 8'd41;  range_lps_tab[31][3] = 8'd48;
        range_lps_tab[32][0] = 8'd27;  range_lps_tab[32][1] = 8'd33;  range_lps_tab[32][2] = 8'd39;  range_lps_tab[32][3] = 8'd45;
        range_lps_tab[33][0] = 8'd26;  range_lps_tab[33][1] = 8'd31;  range_lps_tab[33][2] = 8'd37;  range_lps_tab[33][3] = 8'd43;
        range_lps_tab[34][0] = 8'd24;  range_lps_tab[34][1] = 8'd30;  range_lps_tab[34][2] = 8'd35;  range_lps_tab[34][3] = 8'd41;
        range_lps_tab[35][0] = 8'd23;  range_lps_tab[35][1] = 8'd28;  range_lps_tab[35][2] = 8'd33;  range_lps_tab[35][3] = 8'd39;
        range_lps_tab[36][0] = 8'd22;  range_lps_tab[36][1] = 8'd27;  range_lps_tab[36][2] = 8'd32;  range_lps_tab[36][3] = 8'd37;
        range_lps_tab[37][0] = 8'd21;  range_lps_tab[37][1] = 8'd26;  range_lps_tab[37][2] = 8'd30;  range_lps_tab[37][3] = 8'd35;
        range_lps_tab[38][0] = 8'd20;  range_lps_tab[38][1] = 8'd24;  range_lps_tab[38][2] = 8'd29;  range_lps_tab[38][3] = 8'd33;
        range_lps_tab[39][0] = 8'd19;  range_lps_tab[39][1] = 8'd23;  range_lps_tab[39][2] = 8'd27;  range_lps_tab[39][3] = 8'd31;
        range_lps_tab[40][0] = 8'd18;  range_lps_tab[40][1] = 8'd22;  range_lps_tab[40][2] = 8'd26;  range_lps_tab[40][3] = 8'd30;
        range_lps_tab[41][0] = 8'd17;  range_lps_tab[41][1] = 8'd21;  range_lps_tab[41][2] = 8'd25;  range_lps_tab[41][3] = 8'd28;
        range_lps_tab[42][0] = 8'd16;  range_lps_tab[42][1] = 8'd20;  range_lps_tab[42][2] = 8'd23;  range_lps_tab[42][3] = 8'd27;
        range_lps_tab[43][0] = 8'd15;  range_lps_tab[43][1] = 8'd19;  range_lps_tab[43][2] = 8'd22;  range_lps_tab[43][3] = 8'd25;
        range_lps_tab[44][0] = 8'd14;  range_lps_tab[44][1] = 8'd18;  range_lps_tab[44][2] = 8'd21;  range_lps_tab[44][3] = 8'd24;
        range_lps_tab[45][0] = 8'd14;  range_lps_tab[45][1] = 8'd17;  range_lps_tab[45][2] = 8'd20;  range_lps_tab[45][3] = 8'd23;
        range_lps_tab[46][0] = 8'd13;  range_lps_tab[46][1] = 8'd16;  range_lps_tab[46][2] = 8'd19;  range_lps_tab[46][3] = 8'd22;
        range_lps_tab[47][0] = 8'd12;  range_lps_tab[47][1] = 8'd15;  range_lps_tab[47][2] = 8'd18;  range_lps_tab[47][3] = 8'd21;
        range_lps_tab[48][0] = 8'd12;  range_lps_tab[48][1] = 8'd14;  range_lps_tab[48][2] = 8'd17;  range_lps_tab[48][3] = 8'd20;
        range_lps_tab[49][0] = 8'd11;  range_lps_tab[49][1] = 8'd14;  range_lps_tab[49][2] = 8'd16;  range_lps_tab[49][3] = 8'd19;
        range_lps_tab[50][0] = 8'd11;  range_lps_tab[50][1] = 8'd13;  range_lps_tab[50][2] = 8'd15;  range_lps_tab[50][3] = 8'd18;
        range_lps_tab[51][0] = 8'd10;  range_lps_tab[51][1] = 8'd12;  range_lps_tab[51][2] = 8'd15;  range_lps_tab[51][3] = 8'd17;
        range_lps_tab[52][0] = 8'd10;  range_lps_tab[52][1] = 8'd12;  range_lps_tab[52][2] = 8'd14;  range_lps_tab[52][3] = 8'd16;
        range_lps_tab[53][0] = 8'd9;   range_lps_tab[53][1] = 8'd11;  range_lps_tab[53][2] = 8'd13;  range_lps_tab[53][3] = 8'd15;
        range_lps_tab[54][0] = 8'd9;   range_lps_tab[54][1] = 8'd11;  range_lps_tab[54][2] = 8'd12;  range_lps_tab[54][3] = 8'd14;
        range_lps_tab[55][0] = 8'd8;   range_lps_tab[55][1] = 8'd10;  range_lps_tab[55][2] = 8'd12;  range_lps_tab[55][3] = 8'd14;
        range_lps_tab[56][0] = 8'd8;   range_lps_tab[56][1] = 8'd9;   range_lps_tab[56][2] = 8'd11;  range_lps_tab[56][3] = 8'd13;
        range_lps_tab[57][0] = 8'd7;   range_lps_tab[57][1] = 8'd9;   range_lps_tab[57][2] = 8'd11;  range_lps_tab[57][3] = 8'd12;
        range_lps_tab[58][0] = 8'd7;   range_lps_tab[58][1] = 8'd9;   range_lps_tab[58][2] = 8'd10;  range_lps_tab[58][3] = 8'd12;
        range_lps_tab[59][0] = 8'd7;   range_lps_tab[59][1] = 8'd8;   range_lps_tab[59][2] = 8'd10;  range_lps_tab[59][3] = 8'd11;
        range_lps_tab[60][0] = 8'd6;   range_lps_tab[60][1] = 8'd8;   range_lps_tab[60][2] = 8'd9;   range_lps_tab[60][3] = 8'd11;
        range_lps_tab[61][0] = 8'd6;   range_lps_tab[61][1] = 8'd7;   range_lps_tab[61][2] = 8'd9;   range_lps_tab[61][3] = 8'd10;
        range_lps_tab[62][0] = 8'd6;   range_lps_tab[62][1] = 8'd7;   range_lps_tab[62][2] = 8'd8;   range_lps_tab[62][3] = 8'd9;
        range_lps_tab[63][0] = 8'd2;   range_lps_tab[63][1] = 8'd2;   range_lps_tab[63][2] = 8'd2;   range_lps_tab[63][3] = 8'd2;

        mps_state_tab[ 0] = 6'd1;  mps_state_tab[ 1] = 6'd2;  mps_state_tab[ 2] = 6'd3;  mps_state_tab[ 3] = 6'd4;
        mps_state_tab[ 4] = 6'd5;  mps_state_tab[ 5] = 6'd6;  mps_state_tab[ 6] = 6'd7;  mps_state_tab[ 7] = 6'd8;
        mps_state_tab[ 8] = 6'd9;  mps_state_tab[ 9] = 6'd10; mps_state_tab[10] = 6'd11; mps_state_tab[11] = 6'd12;
        mps_state_tab[12] = 6'd13; mps_state_tab[13] = 6'd14; mps_state_tab[14] = 6'd15; mps_state_tab[15] = 6'd16;
        mps_state_tab[16] = 6'd17; mps_state_tab[17] = 6'd18; mps_state_tab[18] = 6'd19; mps_state_tab[19] = 6'd20;
        mps_state_tab[20] = 6'd21; mps_state_tab[21] = 6'd22; mps_state_tab[22] = 6'd23; mps_state_tab[23] = 6'd24;
        mps_state_tab[24] = 6'd25; mps_state_tab[25] = 6'd26; mps_state_tab[26] = 6'd27; mps_state_tab[27] = 6'd28;
        mps_state_tab[28] = 6'd29; mps_state_tab[29] = 6'd30; mps_state_tab[30] = 6'd31; mps_state_tab[31] = 6'd32;
        mps_state_tab[32] = 6'd33; mps_state_tab[33] = 6'd34; mps_state_tab[34] = 6'd35; mps_state_tab[35] = 6'd36;
        mps_state_tab[36] = 6'd37; mps_state_tab[37] = 6'd38; mps_state_tab[38] = 6'd39; mps_state_tab[39] = 6'd40;
        mps_state_tab[40] = 6'd41; mps_state_tab[41] = 6'd42; mps_state_tab[42] = 6'd43; mps_state_tab[43] = 6'd44;
        mps_state_tab[44] = 6'd45; mps_state_tab[45] = 6'd46; mps_state_tab[46] = 6'd47; mps_state_tab[47] = 6'd48;
        mps_state_tab[48] = 6'd49; mps_state_tab[49] = 6'd50; mps_state_tab[50] = 6'd51; mps_state_tab[51] = 6'd52;
        mps_state_tab[52] = 6'd53; mps_state_tab[53] = 6'd54; mps_state_tab[54] = 6'd55; mps_state_tab[55] = 6'd56;
        mps_state_tab[56] = 6'd57; mps_state_tab[57] = 6'd58; mps_state_tab[58] = 6'd59; mps_state_tab[59] = 6'd60;
        mps_state_tab[60] = 6'd61; mps_state_tab[61] = 6'd62; mps_state_tab[62] = 6'd62; mps_state_tab[63] = 6'd63;

        lps_state_tab[ 0] = 6'd0;  lps_state_tab[ 1] = 6'd0;  lps_state_tab[ 2] = 6'd1;  lps_state_tab[ 3] = 6'd2;
        lps_state_tab[ 4] = 6'd2;  lps_state_tab[ 5] = 6'd4;  lps_state_tab[ 6] = 6'd4;  lps_state_tab[ 7] = 6'd5;
        lps_state_tab[ 8] = 6'd6;  lps_state_tab[ 9] = 6'd7;  lps_state_tab[10] = 6'd8;  lps_state_tab[11] = 6'd9;
        lps_state_tab[12] = 6'd9;  lps_state_tab[13] = 6'd11; lps_state_tab[14] = 6'd11; lps_state_tab[15] = 6'd12;
        lps_state_tab[16] = 6'd13; lps_state_tab[17] = 6'd13; lps_state_tab[18] = 6'd15; lps_state_tab[19] = 6'd15;
        lps_state_tab[20] = 6'd16; lps_state_tab[21] = 6'd16; lps_state_tab[22] = 6'd18; lps_state_tab[23] = 6'd18;
        lps_state_tab[24] = 6'd19; lps_state_tab[25] = 6'd19; lps_state_tab[26] = 6'd21; lps_state_tab[27] = 6'd21;
        lps_state_tab[28] = 6'd22; lps_state_tab[29] = 6'd22; lps_state_tab[30] = 6'd23; lps_state_tab[31] = 6'd24;
        lps_state_tab[32] = 6'd24; lps_state_tab[33] = 6'd25; lps_state_tab[34] = 6'd26; lps_state_tab[35] = 6'd26;
        lps_state_tab[36] = 6'd27; lps_state_tab[37] = 6'd27; lps_state_tab[38] = 6'd28; lps_state_tab[39] = 6'd29;
        lps_state_tab[40] = 6'd29; lps_state_tab[41] = 6'd30; lps_state_tab[42] = 6'd30; lps_state_tab[43] = 6'd30;
        lps_state_tab[44] = 6'd31; lps_state_tab[45] = 6'd32; lps_state_tab[46] = 6'd32; lps_state_tab[47] = 6'd33;
        lps_state_tab[48] = 6'd33; lps_state_tab[49] = 6'd33; lps_state_tab[50] = 6'd34; lps_state_tab[51] = 6'd34;
        lps_state_tab[52] = 6'd35; lps_state_tab[53] = 6'd35; lps_state_tab[54] = 6'd35; lps_state_tab[55] = 6'd36;
        lps_state_tab[56] = 6'd36; lps_state_tab[57] = 6'd36; lps_state_tab[58] = 6'd37; lps_state_tab[59] = 6'd37;
        lps_state_tab[60] = 6'd37; lps_state_tab[61] = 6'd38; lps_state_tab[62] = 6'd38; lps_state_tab[63] = 6'd63;
    end

    assign bin_ready = active;

    task automatic append_raw_bit;
        input       bit_value_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout       overflow_t;
        begin
            if (bit_count_t < 8'd128)
                bits_accum_t[8'd127 - bit_count_t] = bit_value_t;
            else
                overflow_t = 1'b1;
            bit_count_t = bit_count_t + 8'd1;
        end
    endtask

    task automatic append_cabac_bit;
        input       bit_value_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout [7:0] outstanding_t;
        inout       overflow_t;
        integer out_idx;
        begin
            append_raw_bit(bit_value_t, bits_accum_t, bit_count_t, overflow_t);
            for (out_idx = 0; out_idx < outstanding_t; out_idx = out_idx + 1)
                append_raw_bit(~bit_value_t, bits_accum_t, bit_count_t, overflow_t);
            outstanding_t = 8'd0;
        end
    endtask

    task automatic append_raw_bits;
        input [31:0] raw_bits_t;
        input [5:0]  raw_count_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout       overflow_t;
        integer raw_idx;
        begin
            for (raw_idx = raw_count_t - 1; raw_idx >= 0; raw_idx = raw_idx - 1)
                append_raw_bit(raw_bits_t[raw_idx], bits_accum_t, bit_count_t, overflow_t);
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cod_i_low         <= 11'd0;
            cod_i_range       <= 9'd510;
            outstanding_count <= 8'd0;
            bits_valid        <= 1'b0;
            bits_out          <= 128'd0;
            bits_count        <= 8'd0;
            bits_overflow     <= 1'b0;
            ctx_state_wr      <= 1'b0;
            ctx_state_out     <= 7'd0;
            done              <= 1'b0;
            active            <= 1'b0;
        end else begin
            bits_valid    <= 1'b0;
            bits_out      <= 128'd0;
            bits_count    <= 8'd0;
            bits_overflow <= 1'b0;
            ctx_state_wr  <= 1'b0;
            ctx_state_out <= 7'd0;
            done          <= 1'b0;

            if (start) begin
                cod_i_low         <= 11'd0;
                cod_i_range       <= 9'd510;
                outstanding_count <= 8'd0;
                active            <= 1'b1;
            end else if (bin_valid && active) begin
                reg [10:0] low_tmp;
                reg [8:0]  range_tmp;
                reg [7:0]  outstanding_tmp;
                reg [127:0] bits_tmp;
                reg [7:0]  count_tmp;
                reg        overflow_tmp;
                reg [5:0]  pstate_idx;
                reg        val_mps;
                reg [7:0]  range_lps;
                reg [1:0]  qrange_idx;
                integer renorm_iter;

                low_tmp         = cod_i_low;
                range_tmp       = cod_i_range;
                outstanding_tmp = outstanding_count;
                bits_tmp        = 128'd0;
                count_tmp       = 8'd0;
                overflow_tmp    = 1'b0;
                pstate_idx      = ctx_state_in[6:1];
                val_mps         = ctx_state_in[0];

                if (bin_bypass) begin
                    low_tmp = low_tmp << 1;
                    if (bin_value)
                        low_tmp = low_tmp + {2'd0, range_tmp};

                    if (low_tmp < 11'd512) begin
                        append_cabac_bit(1'b0, bits_tmp, count_tmp, outstanding_tmp, overflow_tmp);
                    end else if (low_tmp < 11'd1024) begin
                        outstanding_tmp = outstanding_tmp + 8'd1;
                        low_tmp = low_tmp - 11'd512;
                    end else begin
                        append_cabac_bit(1'b1, bits_tmp, count_tmp, outstanding_tmp, overflow_tmp);
                        low_tmp = low_tmp - 11'd1024;
                    end
                end else if (bin_terminate) begin
                    range_tmp = range_tmp - 9'd2;
                    if (bin_value) begin
                        low_tmp = low_tmp + {2'd0, range_tmp};
                        range_tmp = 9'd2;
                    end

                    for (renorm_iter = 0; renorm_iter < 12; renorm_iter = renorm_iter + 1) begin
                        if (range_tmp < 9'd256) begin
                            if (low_tmp < 11'd256) begin
                                append_cabac_bit(1'b0, bits_tmp, count_tmp, outstanding_tmp, overflow_tmp);
                            end else if (low_tmp < 11'd512) begin
                                outstanding_tmp = outstanding_tmp + 8'd1;
                                low_tmp = low_tmp - 11'd256;
                            end else begin
                                append_cabac_bit(1'b1, bits_tmp, count_tmp, outstanding_tmp, overflow_tmp);
                                low_tmp = low_tmp - 11'd512;
                            end

                            range_tmp = range_tmp << 1;
                            low_tmp   = low_tmp << 1;
                        end
                    end

                    if (bin_value) begin
                        append_cabac_bit(low_tmp[9], bits_tmp, count_tmp, outstanding_tmp, overflow_tmp);
                        append_raw_bits({30'd0, ((low_tmp >> 7) & 2'b11) | 2'b01}, 6'd2, bits_tmp, count_tmp, overflow_tmp);
                    end
                end else begin
                    qrange_idx = cod_i_range[7:6];
                    range_lps = range_lps_tab[pstate_idx][qrange_idx];

                    if (bin_value == val_mps) begin
                        range_tmp = range_tmp - {1'b0, range_lps};
                        pstate_idx = mps_state_tab[pstate_idx];
                    end else begin
                        low_tmp = low_tmp + ({2'd0, range_tmp} - {3'd0, range_lps});
                        range_tmp = {1'b0, range_lps};
                        if (pstate_idx == 6'd0)
                            val_mps = ~val_mps;
                        pstate_idx = lps_state_tab[pstate_idx];
                    end

                    for (renorm_iter = 0; renorm_iter < 12; renorm_iter = renorm_iter + 1) begin
                        if (range_tmp < 9'd256) begin
                            if (low_tmp < 11'd256) begin
                                append_cabac_bit(1'b0, bits_tmp, count_tmp, outstanding_tmp, overflow_tmp);
                            end else if (low_tmp < 11'd512) begin
                                outstanding_tmp = outstanding_tmp + 8'd1;
                                low_tmp = low_tmp - 11'd256;
                            end else begin
                                append_cabac_bit(1'b1, bits_tmp, count_tmp, outstanding_tmp, overflow_tmp);
                                low_tmp = low_tmp - 11'd512;
                            end

                            range_tmp = range_tmp << 1;
                            low_tmp   = low_tmp << 1;
                        end
                    end

                    ctx_state_wr  <= 1'b1;
                    ctx_state_out <= {pstate_idx, val_mps};
                end

                cod_i_low         <= low_tmp;
                cod_i_range       <= range_tmp;
                outstanding_count <= outstanding_tmp;
                bits_out          <= bits_tmp;
                bits_count        <= count_tmp;
                bits_overflow     <= overflow_tmp;
                bits_valid        <= (count_tmp != 8'd0);

                if (bin_terminate && bin_value) begin
                    active <= 1'b0;
                    done   <= 1'b1;
                end
            end
        end
    end

endmodule
