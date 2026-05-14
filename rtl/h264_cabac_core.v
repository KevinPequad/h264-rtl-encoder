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

    reg [7:0] work_range_lps_tab [0:63][0:3];
    reg [5:0] mps_state_tab [0:63];
    reg [5:0] lps_state_tab [0:63];

    reg [63:0] cod_i_low;
    reg [8:0]  cod_i_range;
    reg signed [7:0] cod_i_queue;
    reg [7:0]  outstanding_count;
    reg        pending_byte_valid;
    reg [7:0]  pending_byte;

    // Work registers for the bin-processing combinational step. Kept at module
    // scope because older/open synthesis frontends do not support declarations
    // inside unnamed procedural blocks.
    reg [63:0] work_low_tmp;
    reg [8:0]  work_range_tmp;
    reg signed [7:0] work_queue_tmp;
    reg [7:0]  work_outstanding_tmp;
    reg        work_pending_valid_tmp;
    reg [7:0]  work_pending_byte_tmp;
    reg [127:0] work_bits_tmp;
    reg [7:0]  work_count_tmp;
    reg        work_overflow_tmp;
    reg [5:0]  work_pstate_idx;
    reg        work_val_mps;
    reg [7:0]  work_range_lps;
    reg [1:0]  work_qrange_idx;

    integer idx;
    integer sub;

    initial begin
        work_range_lps_tab[ 0][0] = 8'd2;  work_range_lps_tab[ 0][1] = 8'd2;  work_range_lps_tab[ 0][2] = 8'd2;  work_range_lps_tab[ 0][3] = 8'd2;
        work_range_lps_tab[ 1][0] = 8'd6;  work_range_lps_tab[ 1][1] = 8'd7;  work_range_lps_tab[ 1][2] = 8'd8;  work_range_lps_tab[ 1][3] = 8'd9;
        work_range_lps_tab[ 2][0] = 8'd6;  work_range_lps_tab[ 2][1] = 8'd7;  work_range_lps_tab[ 2][2] = 8'd9;  work_range_lps_tab[ 2][3] = 8'd10;
        work_range_lps_tab[ 3][0] = 8'd6;  work_range_lps_tab[ 3][1] = 8'd8;  work_range_lps_tab[ 3][2] = 8'd9;  work_range_lps_tab[ 3][3] = 8'd11;
        work_range_lps_tab[ 4][0] = 8'd7;  work_range_lps_tab[ 4][1] = 8'd8;  work_range_lps_tab[ 4][2] = 8'd10;  work_range_lps_tab[ 4][3] = 8'd11;
        work_range_lps_tab[ 5][0] = 8'd7;  work_range_lps_tab[ 5][1] = 8'd9;  work_range_lps_tab[ 5][2] = 8'd10;  work_range_lps_tab[ 5][3] = 8'd12;
        work_range_lps_tab[ 6][0] = 8'd7;  work_range_lps_tab[ 6][1] = 8'd9;  work_range_lps_tab[ 6][2] = 8'd11;  work_range_lps_tab[ 6][3] = 8'd12;
        work_range_lps_tab[ 7][0] = 8'd8;  work_range_lps_tab[ 7][1] = 8'd9;  work_range_lps_tab[ 7][2] = 8'd11;  work_range_lps_tab[ 7][3] = 8'd13;
        work_range_lps_tab[ 8][0] = 8'd8;  work_range_lps_tab[ 8][1] = 8'd10;  work_range_lps_tab[ 8][2] = 8'd12;  work_range_lps_tab[ 8][3] = 8'd14;
        work_range_lps_tab[ 9][0] = 8'd9;  work_range_lps_tab[ 9][1] = 8'd11;  work_range_lps_tab[ 9][2] = 8'd12;  work_range_lps_tab[ 9][3] = 8'd14;
        work_range_lps_tab[10][0] = 8'd9;  work_range_lps_tab[10][1] = 8'd11;  work_range_lps_tab[10][2] = 8'd13;  work_range_lps_tab[10][3] = 8'd15;
        work_range_lps_tab[11][0] = 8'd10;  work_range_lps_tab[11][1] = 8'd12;  work_range_lps_tab[11][2] = 8'd14;  work_range_lps_tab[11][3] = 8'd16;
        work_range_lps_tab[12][0] = 8'd10;  work_range_lps_tab[12][1] = 8'd12;  work_range_lps_tab[12][2] = 8'd15;  work_range_lps_tab[12][3] = 8'd17;
        work_range_lps_tab[13][0] = 8'd11;  work_range_lps_tab[13][1] = 8'd13;  work_range_lps_tab[13][2] = 8'd15;  work_range_lps_tab[13][3] = 8'd18;
        work_range_lps_tab[14][0] = 8'd11;  work_range_lps_tab[14][1] = 8'd14;  work_range_lps_tab[14][2] = 8'd16;  work_range_lps_tab[14][3] = 8'd19;
        work_range_lps_tab[15][0] = 8'd12;  work_range_lps_tab[15][1] = 8'd14;  work_range_lps_tab[15][2] = 8'd17;  work_range_lps_tab[15][3] = 8'd20;
        work_range_lps_tab[16][0] = 8'd12;  work_range_lps_tab[16][1] = 8'd15;  work_range_lps_tab[16][2] = 8'd18;  work_range_lps_tab[16][3] = 8'd21;
        work_range_lps_tab[17][0] = 8'd13;  work_range_lps_tab[17][1] = 8'd16;  work_range_lps_tab[17][2] = 8'd19;  work_range_lps_tab[17][3] = 8'd22;
        work_range_lps_tab[18][0] = 8'd14;  work_range_lps_tab[18][1] = 8'd17;  work_range_lps_tab[18][2] = 8'd20;  work_range_lps_tab[18][3] = 8'd23;
        work_range_lps_tab[19][0] = 8'd14;  work_range_lps_tab[19][1] = 8'd18;  work_range_lps_tab[19][2] = 8'd21;  work_range_lps_tab[19][3] = 8'd24;
        work_range_lps_tab[20][0] = 8'd15;  work_range_lps_tab[20][1] = 8'd19;  work_range_lps_tab[20][2] = 8'd22;  work_range_lps_tab[20][3] = 8'd25;
        work_range_lps_tab[21][0] = 8'd16;  work_range_lps_tab[21][1] = 8'd20;  work_range_lps_tab[21][2] = 8'd23;  work_range_lps_tab[21][3] = 8'd27;
        work_range_lps_tab[22][0] = 8'd17;  work_range_lps_tab[22][1] = 8'd21;  work_range_lps_tab[22][2] = 8'd25;  work_range_lps_tab[22][3] = 8'd28;
        work_range_lps_tab[23][0] = 8'd18;  work_range_lps_tab[23][1] = 8'd22;  work_range_lps_tab[23][2] = 8'd26;  work_range_lps_tab[23][3] = 8'd30;
        work_range_lps_tab[24][0] = 8'd19;  work_range_lps_tab[24][1] = 8'd23;  work_range_lps_tab[24][2] = 8'd27;  work_range_lps_tab[24][3] = 8'd31;
        work_range_lps_tab[25][0] = 8'd20;  work_range_lps_tab[25][1] = 8'd24;  work_range_lps_tab[25][2] = 8'd29;  work_range_lps_tab[25][3] = 8'd33;
        work_range_lps_tab[26][0] = 8'd21;  work_range_lps_tab[26][1] = 8'd26;  work_range_lps_tab[26][2] = 8'd30;  work_range_lps_tab[26][3] = 8'd35;
        work_range_lps_tab[27][0] = 8'd22;  work_range_lps_tab[27][1] = 8'd27;  work_range_lps_tab[27][2] = 8'd32;  work_range_lps_tab[27][3] = 8'd37;
        work_range_lps_tab[28][0] = 8'd23;  work_range_lps_tab[28][1] = 8'd28;  work_range_lps_tab[28][2] = 8'd33;  work_range_lps_tab[28][3] = 8'd39;
        work_range_lps_tab[29][0] = 8'd24;  work_range_lps_tab[29][1] = 8'd30;  work_range_lps_tab[29][2] = 8'd35;  work_range_lps_tab[29][3] = 8'd41;
        work_range_lps_tab[30][0] = 8'd26;  work_range_lps_tab[30][1] = 8'd31;  work_range_lps_tab[30][2] = 8'd37;  work_range_lps_tab[30][3] = 8'd43;
        work_range_lps_tab[31][0] = 8'd27;  work_range_lps_tab[31][1] = 8'd33;  work_range_lps_tab[31][2] = 8'd39;  work_range_lps_tab[31][3] = 8'd45;
        work_range_lps_tab[32][0] = 8'd29;  work_range_lps_tab[32][1] = 8'd35;  work_range_lps_tab[32][2] = 8'd41;  work_range_lps_tab[32][3] = 8'd48;
        work_range_lps_tab[33][0] = 8'd30;  work_range_lps_tab[33][1] = 8'd37;  work_range_lps_tab[33][2] = 8'd43;  work_range_lps_tab[33][3] = 8'd50;
        work_range_lps_tab[34][0] = 8'd32;  work_range_lps_tab[34][1] = 8'd39;  work_range_lps_tab[34][2] = 8'd46;  work_range_lps_tab[34][3] = 8'd53;
        work_range_lps_tab[35][0] = 8'd33;  work_range_lps_tab[35][1] = 8'd41;  work_range_lps_tab[35][2] = 8'd48;  work_range_lps_tab[35][3] = 8'd56;
        work_range_lps_tab[36][0] = 8'd35;  work_range_lps_tab[36][1] = 8'd43;  work_range_lps_tab[36][2] = 8'd51;  work_range_lps_tab[36][3] = 8'd59;
        work_range_lps_tab[37][0] = 8'd37;  work_range_lps_tab[37][1] = 8'd45;  work_range_lps_tab[37][2] = 8'd54;  work_range_lps_tab[37][3] = 8'd62;
        work_range_lps_tab[38][0] = 8'd39;  work_range_lps_tab[38][1] = 8'd48;  work_range_lps_tab[38][2] = 8'd56;  work_range_lps_tab[38][3] = 8'd65;
        work_range_lps_tab[39][0] = 8'd41;  work_range_lps_tab[39][1] = 8'd50;  work_range_lps_tab[39][2] = 8'd59;  work_range_lps_tab[39][3] = 8'd69;
        work_range_lps_tab[40][0] = 8'd43;  work_range_lps_tab[40][1] = 8'd53;  work_range_lps_tab[40][2] = 8'd63;  work_range_lps_tab[40][3] = 8'd72;
        work_range_lps_tab[41][0] = 8'd46;  work_range_lps_tab[41][1] = 8'd56;  work_range_lps_tab[41][2] = 8'd66;  work_range_lps_tab[41][3] = 8'd76;
        work_range_lps_tab[42][0] = 8'd48;  work_range_lps_tab[42][1] = 8'd59;  work_range_lps_tab[42][2] = 8'd69;  work_range_lps_tab[42][3] = 8'd80;
        work_range_lps_tab[43][0] = 8'd51;  work_range_lps_tab[43][1] = 8'd62;  work_range_lps_tab[43][2] = 8'd73;  work_range_lps_tab[43][3] = 8'd85;
        work_range_lps_tab[44][0] = 8'd53;  work_range_lps_tab[44][1] = 8'd65;  work_range_lps_tab[44][2] = 8'd77;  work_range_lps_tab[44][3] = 8'd89;
        work_range_lps_tab[45][0] = 8'd56;  work_range_lps_tab[45][1] = 8'd69;  work_range_lps_tab[45][2] = 8'd81;  work_range_lps_tab[45][3] = 8'd94;
        work_range_lps_tab[46][0] = 8'd59;  work_range_lps_tab[46][1] = 8'd72;  work_range_lps_tab[46][2] = 8'd86;  work_range_lps_tab[46][3] = 8'd99;
        work_range_lps_tab[47][0] = 8'd62;  work_range_lps_tab[47][1] = 8'd76;  work_range_lps_tab[47][2] = 8'd90;  work_range_lps_tab[47][3] = 8'd104;
        work_range_lps_tab[48][0] = 8'd66;  work_range_lps_tab[48][1] = 8'd80;  work_range_lps_tab[48][2] = 8'd95;  work_range_lps_tab[48][3] = 8'd110;
        work_range_lps_tab[49][0] = 8'd69;  work_range_lps_tab[49][1] = 8'd85;  work_range_lps_tab[49][2] = 8'd100;  work_range_lps_tab[49][3] = 8'd116;
        work_range_lps_tab[50][0] = 8'd73;  work_range_lps_tab[50][1] = 8'd89;  work_range_lps_tab[50][2] = 8'd105;  work_range_lps_tab[50][3] = 8'd122;
        work_range_lps_tab[51][0] = 8'd77;  work_range_lps_tab[51][1] = 8'd94;  work_range_lps_tab[51][2] = 8'd111;  work_range_lps_tab[51][3] = 8'd128;
        work_range_lps_tab[52][0] = 8'd81;  work_range_lps_tab[52][1] = 8'd99;  work_range_lps_tab[52][2] = 8'd117;  work_range_lps_tab[52][3] = 8'd135;
        work_range_lps_tab[53][0] = 8'd85;  work_range_lps_tab[53][1] = 8'd104;  work_range_lps_tab[53][2] = 8'd123;  work_range_lps_tab[53][3] = 8'd142;
        work_range_lps_tab[54][0] = 8'd90;  work_range_lps_tab[54][1] = 8'd110;  work_range_lps_tab[54][2] = 8'd130;  work_range_lps_tab[54][3] = 8'd150;
        work_range_lps_tab[55][0] = 8'd95;  work_range_lps_tab[55][1] = 8'd116;  work_range_lps_tab[55][2] = 8'd137;  work_range_lps_tab[55][3] = 8'd158;
        work_range_lps_tab[56][0] = 8'd100;  work_range_lps_tab[56][1] = 8'd122;  work_range_lps_tab[56][2] = 8'd144;  work_range_lps_tab[56][3] = 8'd166;
        work_range_lps_tab[57][0] = 8'd105;  work_range_lps_tab[57][1] = 8'd128;  work_range_lps_tab[57][2] = 8'd152;  work_range_lps_tab[57][3] = 8'd175;
        work_range_lps_tab[58][0] = 8'd111;  work_range_lps_tab[58][1] = 8'd135;  work_range_lps_tab[58][2] = 8'd160;  work_range_lps_tab[58][3] = 8'd185;
        work_range_lps_tab[59][0] = 8'd116;  work_range_lps_tab[59][1] = 8'd142;  work_range_lps_tab[59][2] = 8'd169;  work_range_lps_tab[59][3] = 8'd195;
        work_range_lps_tab[60][0] = 8'd123;  work_range_lps_tab[60][1] = 8'd150;  work_range_lps_tab[60][2] = 8'd178;  work_range_lps_tab[60][3] = 8'd205;
        work_range_lps_tab[61][0] = 8'd128;  work_range_lps_tab[61][1] = 8'd158;  work_range_lps_tab[61][2] = 8'd187;  work_range_lps_tab[61][3] = 8'd216;
        work_range_lps_tab[62][0] = 8'd128;  work_range_lps_tab[62][1] = 8'd167;  work_range_lps_tab[62][2] = 8'd197;  work_range_lps_tab[62][3] = 8'd227;
        work_range_lps_tab[63][0] = 8'd128;  work_range_lps_tab[63][1] = 8'd176;  work_range_lps_tab[63][2] = 8'd208;  work_range_lps_tab[63][3] = 8'd240;

        mps_state_tab[ 0] = 6'd0;  mps_state_tab[ 1] = 6'd1;  mps_state_tab[ 2] = 6'd1;  mps_state_tab[ 3] = 6'd2;
        mps_state_tab[ 4] = 6'd3;  mps_state_tab[ 5] = 6'd4;  mps_state_tab[ 6] = 6'd5;  mps_state_tab[ 7] = 6'd6;
        mps_state_tab[ 8] = 6'd7;  mps_state_tab[ 9] = 6'd8;  mps_state_tab[10] = 6'd9;  mps_state_tab[11] = 6'd10;
        mps_state_tab[12] = 6'd11; mps_state_tab[13] = 6'd12; mps_state_tab[14] = 6'd13; mps_state_tab[15] = 6'd14;
        mps_state_tab[16] = 6'd15; mps_state_tab[17] = 6'd16; mps_state_tab[18] = 6'd17; mps_state_tab[19] = 6'd18;
        mps_state_tab[20] = 6'd19; mps_state_tab[21] = 6'd20; mps_state_tab[22] = 6'd21; mps_state_tab[23] = 6'd22;
        mps_state_tab[24] = 6'd23; mps_state_tab[25] = 6'd24; mps_state_tab[26] = 6'd25; mps_state_tab[27] = 6'd26;
        mps_state_tab[28] = 6'd27; mps_state_tab[29] = 6'd28; mps_state_tab[30] = 6'd29; mps_state_tab[31] = 6'd30;
        mps_state_tab[32] = 6'd31; mps_state_tab[33] = 6'd32; mps_state_tab[34] = 6'd33; mps_state_tab[35] = 6'd34;
        mps_state_tab[36] = 6'd35; mps_state_tab[37] = 6'd36; mps_state_tab[38] = 6'd37; mps_state_tab[39] = 6'd38;
        mps_state_tab[40] = 6'd39; mps_state_tab[41] = 6'd40; mps_state_tab[42] = 6'd41; mps_state_tab[43] = 6'd42;
        mps_state_tab[44] = 6'd43; mps_state_tab[45] = 6'd44; mps_state_tab[46] = 6'd45; mps_state_tab[47] = 6'd46;
        mps_state_tab[48] = 6'd47; mps_state_tab[49] = 6'd48; mps_state_tab[50] = 6'd49; mps_state_tab[51] = 6'd50;
        mps_state_tab[52] = 6'd51; mps_state_tab[53] = 6'd52; mps_state_tab[54] = 6'd53; mps_state_tab[55] = 6'd54;
        mps_state_tab[56] = 6'd55; mps_state_tab[57] = 6'd56; mps_state_tab[58] = 6'd57; mps_state_tab[59] = 6'd58;
        mps_state_tab[60] = 6'd59; mps_state_tab[61] = 6'd60; mps_state_tab[62] = 6'd61; mps_state_tab[63] = 6'd62;

        lps_state_tab[ 0] = 6'd0;  lps_state_tab[ 1] = 6'd25; lps_state_tab[ 2] = 6'd25; lps_state_tab[ 3] = 6'd26;
        lps_state_tab[ 4] = 6'd26; lps_state_tab[ 5] = 6'd26; lps_state_tab[ 6] = 6'd27; lps_state_tab[ 7] = 6'd27;
        lps_state_tab[ 8] = 6'd27; lps_state_tab[ 9] = 6'd28; lps_state_tab[10] = 6'd28; lps_state_tab[11] = 6'd28;
        lps_state_tab[12] = 6'd29; lps_state_tab[13] = 6'd29; lps_state_tab[14] = 6'd30; lps_state_tab[15] = 6'd30;
        lps_state_tab[16] = 6'd30; lps_state_tab[17] = 6'd31; lps_state_tab[18] = 6'd31; lps_state_tab[19] = 6'd32;
        lps_state_tab[20] = 6'd33; lps_state_tab[21] = 6'd33; lps_state_tab[22] = 6'd33; lps_state_tab[23] = 6'd34;
        lps_state_tab[24] = 6'd34; lps_state_tab[25] = 6'd35; lps_state_tab[26] = 6'd36; lps_state_tab[27] = 6'd36;
        lps_state_tab[28] = 6'd37; lps_state_tab[29] = 6'd37; lps_state_tab[30] = 6'd38; lps_state_tab[31] = 6'd39;
        lps_state_tab[32] = 6'd39; lps_state_tab[33] = 6'd40; lps_state_tab[34] = 6'd41; lps_state_tab[35] = 6'd41;
        lps_state_tab[36] = 6'd42; lps_state_tab[37] = 6'd42; lps_state_tab[38] = 6'd44; lps_state_tab[39] = 6'd44;
        lps_state_tab[40] = 6'd45; lps_state_tab[41] = 6'd45; lps_state_tab[42] = 6'd47; lps_state_tab[43] = 6'd47;
        lps_state_tab[44] = 6'd48; lps_state_tab[45] = 6'd48; lps_state_tab[46] = 6'd50; lps_state_tab[47] = 6'd50;
        lps_state_tab[48] = 6'd51; lps_state_tab[49] = 6'd52; lps_state_tab[50] = 6'd52; lps_state_tab[51] = 6'd54;
        lps_state_tab[52] = 6'd54; lps_state_tab[53] = 6'd55; lps_state_tab[54] = 6'd56; lps_state_tab[55] = 6'd57;
        lps_state_tab[56] = 6'd58; lps_state_tab[57] = 6'd59; lps_state_tab[58] = 6'd59; lps_state_tab[59] = 6'd61;
        lps_state_tab[60] = 6'd61; lps_state_tab[61] = 6'd62; lps_state_tab[62] = 6'd63; lps_state_tab[63] = 6'd63;
    end

    assign bin_ready = active;

    task automatic append_byte;
        input [7:0] byte_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout overflow_t;
        begin
            if (bit_count_t <= 8'd120)
                bits_accum_t = bits_accum_t | ({byte_t, 120'd0} >> bit_count_t);
            else
                overflow_t = 1'b1;
            bit_count_t = bit_count_t + 8'd8;
        end
    endtask

    task automatic resolve_out_byte;
        input [8:0] out_t;
        inout pending_valid_t;
        inout [7:0] pending_byte_t;
        inout [7:0] outstanding_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout overflow_t;
        integer out_idx;
        reg carry_t;
        begin
            if (out_t[7:0] == 8'hFF) begin
                outstanding_t = outstanding_t + 8'd1;
            end else begin
                carry_t = out_t[8];
                if (pending_valid_t)
                    append_byte(pending_byte_t + {7'd0, carry_t}, bits_accum_t, bit_count_t, overflow_t);
                else if (carry_t)
                    overflow_t = 1'b1;

                for (out_idx = 0; out_idx < 16; out_idx = out_idx + 1) begin
                    if (out_idx < outstanding_t)
                        append_byte(carry_t ? 8'h00 : 8'hFF, bits_accum_t, bit_count_t, overflow_t);
                end
                if (outstanding_t > 8'd16)
                    overflow_t = 1'b1;

                pending_byte_t = out_t[7:0];
                pending_valid_t = 1'b1;
                outstanding_t = 8'd0;
            end
        end
    endtask

    task automatic cabac_putbyte;
        inout [63:0] low_t;
        inout signed [7:0] queue_t;
        inout [7:0] outstanding_t;
        inout pending_valid_t;
        inout [7:0] pending_byte_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout overflow_t;
        reg [8:0] out_t;
        reg [63:0] mask_t;
        integer queue_i;
        begin
            if (queue_t >= 0) begin
                queue_i = queue_t;
                out_t = low_t >> (queue_i + 10);
                mask_t = (64'h0000_0000_0000_0400 << queue_i) - 64'd1;
                low_t = low_t & mask_t;
                queue_t = queue_t - 8;
                resolve_out_byte(out_t, pending_valid_t, pending_byte_t,
                                 outstanding_t, bits_accum_t, bit_count_t, overflow_t);
            end
        end
    endtask

    task automatic cabac_renorm;
        inout [63:0] low_t;
        inout [8:0]  range_t;
        inout signed [7:0] queue_t;
        inout [7:0] outstanding_t;
        inout pending_valid_t;
        inout [7:0] pending_byte_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout overflow_t;
        integer shift_t;
        integer renorm_i;
        begin
            shift_t = 0;
            for (renorm_i = 0; renorm_i < 8; renorm_i = renorm_i + 1) begin
                if (range_t < 9'd256) begin
                    range_t = range_t << 1;
                    shift_t = shift_t + 1;
                end
            end
            if (shift_t != 0) begin
                low_t = low_t << shift_t;
                queue_t = queue_t + shift_t;
                cabac_putbyte(low_t, queue_t, outstanding_t, pending_valid_t,
                              pending_byte_t, bits_accum_t, bit_count_t, overflow_t);
            end
        end
    endtask

    task automatic cabac_flush;
        inout [63:0] low_t;
        inout [8:0]  range_t;
        inout signed [7:0] queue_t;
        inout [7:0] outstanding_t;
        inout pending_valid_t;
        inout [7:0] pending_byte_t;
        inout [127:0] bits_accum_t;
        inout [7:0] bit_count_t;
        inout overflow_t;
        integer shift_i;
        integer out_idx;
        begin
            low_t = low_t + range_t - 9'd2;
            low_t = low_t | 64'd1;
            low_t = low_t << 9;
            queue_t = queue_t + 9;
            cabac_putbyte(low_t, queue_t, outstanding_t, pending_valid_t,
                          pending_byte_t, bits_accum_t, bit_count_t, overflow_t);
            cabac_putbyte(low_t, queue_t, outstanding_t, pending_valid_t,
                          pending_byte_t, bits_accum_t, bit_count_t, overflow_t);

            if (queue_t < 0) begin
                shift_i = -queue_t;
                low_t = low_t << shift_i;
            end
            queue_t = 0;
            cabac_putbyte(low_t, queue_t, outstanding_t, pending_valid_t,
                          pending_byte_t, bits_accum_t, bit_count_t, overflow_t);

            if (pending_valid_t) begin
                append_byte(pending_byte_t, bits_accum_t, bit_count_t, overflow_t);
                pending_valid_t = 1'b0;
            end
            for (out_idx = 0; out_idx < 16; out_idx = out_idx + 1) begin
                if (out_idx < outstanding_t)
                    append_byte(8'hFF, bits_accum_t, bit_count_t, overflow_t);
            end
            if (outstanding_t > 8'd16)
                overflow_t = 1'b1;
            outstanding_t = 8'd0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cod_i_low         <= 64'd0;
            cod_i_range       <= 9'd510;
            cod_i_queue       <= -8'sd9;
            outstanding_count <= 8'd0;
            pending_byte_valid <= 1'b0;
            pending_byte      <= 8'd0;
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
                cod_i_low         <= 64'd0;
                cod_i_range       <= 9'd510;
                cod_i_queue       <= -8'sd9;
                outstanding_count <= 8'd0;
                pending_byte_valid <= 1'b0;
                pending_byte      <= 8'd0;
                active            <= 1'b1;
            end else if (bin_valid && active) begin
                work_low_tmp         = cod_i_low;
                work_range_tmp       = cod_i_range;
                work_queue_tmp       = cod_i_queue;
                work_outstanding_tmp = outstanding_count;
                work_pending_valid_tmp = pending_byte_valid;
                work_pending_byte_tmp = pending_byte;
                work_bits_tmp        = 128'd0;
                work_count_tmp       = 8'd0;
                work_overflow_tmp    = 1'b0;
                work_pstate_idx      = ctx_state_in[6:1];
                work_val_mps         = ctx_state_in[0];

                if (bin_bypass) begin
                    work_low_tmp = work_low_tmp << 1;
                    if (bin_value)
                        work_low_tmp = work_low_tmp + {55'd0, work_range_tmp};
                    work_queue_tmp = work_queue_tmp + 8'sd1;
                    cabac_putbyte(work_low_tmp, work_queue_tmp, work_outstanding_tmp, work_pending_valid_tmp,
                                  work_pending_byte_tmp, work_bits_tmp, work_count_tmp, work_overflow_tmp);
                end else if (bin_terminate) begin
                    if (bin_value) begin
                        cabac_flush(work_low_tmp, work_range_tmp, work_queue_tmp, work_outstanding_tmp,
                                    work_pending_valid_tmp, work_pending_byte_tmp,
                                    work_bits_tmp, work_count_tmp, work_overflow_tmp);
                        active <= 1'b0;
                        done   <= 1'b1;
                    end else begin
                        work_range_tmp = work_range_tmp - 9'd2;
                        cabac_renorm(work_low_tmp, work_range_tmp, work_queue_tmp, work_outstanding_tmp,
                                     work_pending_valid_tmp, work_pending_byte_tmp,
                                     work_bits_tmp, work_count_tmp, work_overflow_tmp);
                    end
                end else begin
                    work_qrange_idx = work_range_tmp[7:6];
                    work_range_lps = work_range_lps_tab[work_pstate_idx][work_qrange_idx];

                    if (bin_value == work_val_mps) begin
                        work_range_tmp = work_range_tmp - {1'b0, work_range_lps};
                        work_pstate_idx = mps_state_tab[work_pstate_idx];
                    end else begin
                        work_low_tmp = work_low_tmp + ({55'd0, work_range_tmp} - {56'd0, work_range_lps});
                        work_range_tmp = {1'b0, work_range_lps};
                        if (work_pstate_idx == 6'd0)
                            work_val_mps = ~work_val_mps;
                        work_pstate_idx = lps_state_tab[work_pstate_idx];
                    end

                    cabac_renorm(work_low_tmp, work_range_tmp, work_queue_tmp, work_outstanding_tmp,
                                 work_pending_valid_tmp, work_pending_byte_tmp,
                                 work_bits_tmp, work_count_tmp, work_overflow_tmp);

                    ctx_state_wr  <= 1'b1;
                    ctx_state_out <= {work_pstate_idx, work_val_mps};
                end

                cod_i_low         <= work_low_tmp;
                cod_i_range       <= work_range_tmp;
                cod_i_queue       <= work_queue_tmp;
                outstanding_count <= work_outstanding_tmp;
                pending_byte_valid <= work_pending_valid_tmp;
                pending_byte      <= work_pending_byte_tmp;
                bits_out          <= work_bits_tmp;
                bits_count        <= work_count_tmp;
                bits_overflow     <= work_overflow_tmp;
                bits_valid        <= (work_count_tmp != 8'd0);
            end
        end
    end

endmodule
