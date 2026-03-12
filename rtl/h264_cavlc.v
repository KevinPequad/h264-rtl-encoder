// h264_cavlc.v — CAVLC Entropy Coding for H.264
// Encodes one 4x4 block of quantized coefficients into bitstream fragments
// All VLC tables are implemented as combinational logic (no tasks).
// Output: MSB-justified bits in bits_out[31:0], bits_count valid bits.

module h264_cavlc (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Input: scan-ordered coefficients (256 bits = 16 * 16-bit signed)
    input  wire [255:0] scan_flat,
    input  wire [4:0]   total_coeffs,
    input  wire [1:0]   trailing_ones,
    input  wire [3:0]   last_nonzero_idx,
    input  wire [4:0]   nC,
    input  wire        is_chroma_dc,   // 1 = chroma DC block (nC=-1)
    input  wire        chroma_dc_422,  // 1 = 4:2:2 chroma DC (maxCoeff=8), 0 = 4:2:0 (maxCoeff=4)
    input  wire        is_chroma_ac,   // 1 = chroma AC block (maxCoeff=15)

    // Output bitstream fragment
    output reg  [31:0] bits_out,
    output reg  [5:0]  bits_count,
    output reg         bits_valid
);

    // States
    localparam S_IDLE        = 4'd0;
    localparam S_COEFF_TOKEN = 4'd1;
    localparam S_COLLECT     = 4'd2;
    localparam S_TRAIL_SIGNS = 4'd3;
    localparam S_LEV_SETUP   = 4'd4;
    localparam S_LEV_EMIT    = 4'd5;
    localparam S_TZ_SETUP    = 4'd6;
    localparam S_TZ_EMIT     = 4'd7;
    localparam S_RB_SETUP    = 4'd8;
    localparam S_RB_EMIT     = 4'd9;
    localparam S_DONE        = 4'd10;
    localparam S_LEV_EMIT_LO = 4'd11;

    reg [3:0] state;

    // Non-zero coefficient storage
    reg signed [15:0] nz_val [0:15];
    reg [3:0]  nz_run [0:15];
    reg [4:0]  nz_cnt;
    reg [3:0]  total_zeros_r;
    reg [3:0]  zeros_left;

    reg [4:0]  idx;
    reg [3:0]  zero_run_cnt;
    reg [3:0]  suffix_len;

    // Temporaries for level computation
    reg signed [15:0] cur_val;
    reg [15:0] cur_abs;
    reg        cur_sign;
    reg [15:0] level_code_w;

    // =====================================================================
    // coeff_token ROM (nC=0..1, MSB-justified code in 16 bits)
    // =====================================================================
    reg [5:0]  ct_len;
    reg [15:0] ct_code;
    wire [1:0] nc_idx = (nC >= 5'd8) ? 2'd3 : (nC >= 5'd4) ? 2'd2 : (nC >= 5'd2) ? 2'd1 : 2'd0;

    // Chroma DC coeff_token tables
    // 4:2:0: nC=-1, maxNumCoeff=4, Table 9-5
    // 4:2:2: nC=-2, maxNumCoeff=8, from FFmpeg chroma422_dc_coeff_token
    reg [5:0]  chr_dc_ct_len;
    reg [15:0] chr_dc_ct_code;

    // 4:2:0 chroma DC coeff_token (nC=-1)
    reg [5:0]  chr420_ct_len;
    reg [15:0] chr420_ct_code;
    always @(*) begin
        chr420_ct_len  = 6'd2;
        chr420_ct_code = 16'h4000;
        case ({total_coeffs[2:0], trailing_ones})
            {3'd0, 2'd0}: begin chr420_ct_len= 6'd2; chr420_ct_code=16'h4000; end // 01
            {3'd1, 2'd0}: begin chr420_ct_len= 6'd6; chr420_ct_code=16'h1C00; end // 000111
            {3'd1, 2'd1}: begin chr420_ct_len= 6'd1; chr420_ct_code=16'h8000; end // 1
            {3'd2, 2'd0}: begin chr420_ct_len= 6'd6; chr420_ct_code=16'h1000; end // 000100
            {3'd2, 2'd1}: begin chr420_ct_len= 6'd6; chr420_ct_code=16'h1800; end // 000110
            {3'd2, 2'd2}: begin chr420_ct_len= 6'd3; chr420_ct_code=16'h2000; end // 001
            {3'd3, 2'd0}: begin chr420_ct_len= 6'd6; chr420_ct_code=16'h0C00; end // 000011
            {3'd3, 2'd1}: begin chr420_ct_len= 6'd7; chr420_ct_code=16'h0600; end // 0000011
            {3'd3, 2'd2}: begin chr420_ct_len= 6'd7; chr420_ct_code=16'h0400; end // 0000010
            {3'd3, 2'd3}: begin chr420_ct_len= 6'd6; chr420_ct_code=16'h1400; end // 000101
            {3'd4, 2'd0}: begin chr420_ct_len= 6'd6; chr420_ct_code=16'h0800; end // 000010
            {3'd4, 2'd1}: begin chr420_ct_len= 6'd8; chr420_ct_code=16'h0300; end // 00000011
            {3'd4, 2'd2}: begin chr420_ct_len= 6'd8; chr420_ct_code=16'h0200; end // 00000010
            {3'd4, 2'd3}: begin chr420_ct_len= 6'd7; chr420_ct_code=16'h0000; end // 0000000
            default: begin chr420_ct_len= 6'd2; chr420_ct_code=16'h4000; end
        endcase
    end

    // 4:2:2 chroma DC coeff_token (nC=-2, maxNumCoeff=8)
    // From FFmpeg chroma422_dc_coeff_token_{bits,len} tables
    // Codeword bits are MSB-justified in 16 bits
    reg [5:0]  chr422_ct_len;
    reg [15:0] chr422_ct_code;
    always @(*) begin
        chr422_ct_len  = 6'd1;
        chr422_ct_code = 16'h8000;
        case ({total_coeffs[3:0], trailing_ones})
            // TC=0: len=1, bits=1 -> 1
            {4'd0, 2'd0}: begin chr422_ct_len= 6'd1;  chr422_ct_code=16'h8000; end
            // TC=1: T1=0: len=7 bits=15(0001111), T1=1: len=2 bits=1(01)
            {4'd1, 2'd0}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1E00; end
            {4'd1, 2'd1}: begin chr422_ct_len= 6'd2;  chr422_ct_code=16'h4000; end
            // TC=2: T1=0: len=7 bits=14(0001110), T1=1: len=7 bits=13(0001101), T1=2: len=3 bits=1(001)
            {4'd2, 2'd0}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1C00; end
            {4'd2, 2'd1}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1A00; end
            {4'd2, 2'd2}: begin chr422_ct_len= 6'd3;  chr422_ct_code=16'h2000; end
            // TC=3: T1=0: len=9 bits=7(000000111), T1=1: len=7 bits=12(0001100), T1=2: len=7 bits=11(0001011), T1=3: len=5 bits=1(00001)
            {4'd3, 2'd0}: begin chr422_ct_len= 6'd9;  chr422_ct_code=16'h0380; end
            {4'd3, 2'd1}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1800; end
            {4'd3, 2'd2}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1600; end
            {4'd3, 2'd3}: begin chr422_ct_len= 6'd5;  chr422_ct_code=16'h0800; end
            // TC=4: T1=0: len=9 bits=6(000000110), T1=1: len=9 bits=5(000000101), T1=2: len=7 bits=10(0001010), T1=3: len=6 bits=1(000001)
            {4'd4, 2'd0}: begin chr422_ct_len= 6'd9;  chr422_ct_code=16'h0300; end
            {4'd4, 2'd1}: begin chr422_ct_len= 6'd9;  chr422_ct_code=16'h0280; end
            {4'd4, 2'd2}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1400; end
            {4'd4, 2'd3}: begin chr422_ct_len= 6'd6;  chr422_ct_code=16'h0400; end
            // TC=5: T1=0: len=10 bits=7(0000000111), T1=1: len=10 bits=6(0000000110), T1=2: len=9 bits=4(000000100), T1=3: len=7 bits=9(0001001)
            {4'd5, 2'd0}: begin chr422_ct_len= 6'd10; chr422_ct_code=16'h01C0; end
            {4'd5, 2'd1}: begin chr422_ct_len= 6'd10; chr422_ct_code=16'h0180; end
            {4'd5, 2'd2}: begin chr422_ct_len= 6'd9;  chr422_ct_code=16'h0200; end
            {4'd5, 2'd3}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1200; end
            // TC=6: T1=0: len=11 bits=7(00000000111), T1=1: len=11 bits=6(00000000110), T1=2: len=10 bits=5(0000000101), T1=3: len=7 bits=8(0001000)
            {4'd6, 2'd0}: begin chr422_ct_len= 6'd11; chr422_ct_code=16'h00E0; end
            {4'd6, 2'd1}: begin chr422_ct_len= 6'd11; chr422_ct_code=16'h00C0; end
            {4'd6, 2'd2}: begin chr422_ct_len= 6'd10; chr422_ct_code=16'h0140; end
            {4'd6, 2'd3}: begin chr422_ct_len= 6'd7;  chr422_ct_code=16'h1000; end
            // TC=7: T1=0: len=12 bits=7(000000000111), T1=1: len=12 bits=6(000000000110), T1=2: len=11 bits=5(00000000101), T1=3: len=10 bits=4(0000000100)
            {4'd7, 2'd0}: begin chr422_ct_len= 6'd12; chr422_ct_code=16'h0070; end
            {4'd7, 2'd1}: begin chr422_ct_len= 6'd12; chr422_ct_code=16'h0060; end
            {4'd7, 2'd2}: begin chr422_ct_len= 6'd11; chr422_ct_code=16'h00A0; end
            {4'd7, 2'd3}: begin chr422_ct_len= 6'd10; chr422_ct_code=16'h0100; end
            // TC=8: T1=0: len=13 bits=7(0000000000111), T1=1: len=12 bits=5(000000000101), T1=2: len=12 bits=4(000000000100), T1=3: len=11 bits=4(00000000100)
            {4'd8, 2'd0}: begin chr422_ct_len= 6'd13; chr422_ct_code=16'h0038; end
            {4'd8, 2'd1}: begin chr422_ct_len= 6'd12; chr422_ct_code=16'h0050; end
            {4'd8, 2'd2}: begin chr422_ct_len= 6'd12; chr422_ct_code=16'h0040; end
            {4'd8, 2'd3}: begin chr422_ct_len= 6'd11; chr422_ct_code=16'h0080; end
            default: begin chr422_ct_len= 6'd1; chr422_ct_code=16'h8000; end
        endcase
    end

    // Select between 4:2:0 and 4:2:2 chroma DC coeff_token
    always @(*) begin
        if (chroma_dc_422) begin
            chr_dc_ct_len  = chr422_ct_len;
            chr_dc_ct_code = chr422_ct_code;
        end else begin
            chr_dc_ct_len  = chr420_ct_len;
            chr_dc_ct_code = chr420_ct_code;
        end
    end

    always @(*) begin
        ct_len  = 6'd1;
        ct_code = 16'h8000;
        if (is_chroma_dc) begin
            ct_len  = chr_dc_ct_len;
            ct_code = chr_dc_ct_code;
        end else
        case (nc_idx)
            2'd0: case ({total_coeffs, trailing_ones})
                {5'd0, 2'd0}: begin ct_len= 6'd1; ct_code=16'h8000; end
                {5'd1, 2'd0}: begin ct_len= 6'd6; ct_code=16'h1400; end
                {5'd1, 2'd1}: begin ct_len= 6'd2; ct_code=16'h4000; end
                {5'd2, 2'd0}: begin ct_len= 6'd8; ct_code=16'h0700; end
                {5'd2, 2'd1}: begin ct_len= 6'd6; ct_code=16'h1000; end
                {5'd2, 2'd2}: begin ct_len= 6'd3; ct_code=16'h2000; end
                {5'd3, 2'd0}: begin ct_len= 6'd9; ct_code=16'h0380; end
                {5'd3, 2'd1}: begin ct_len= 6'd8; ct_code=16'h0600; end
                {5'd3, 2'd2}: begin ct_len= 6'd7; ct_code=16'h0A00; end
                {5'd3, 2'd3}: begin ct_len= 6'd5; ct_code=16'h1800; end
                {5'd4, 2'd0}: begin ct_len= 6'd10; ct_code=16'h01C0; end
                {5'd4, 2'd1}: begin ct_len= 6'd9; ct_code=16'h0300; end
                {5'd4, 2'd2}: begin ct_len= 6'd8; ct_code=16'h0500; end
                {5'd4, 2'd3}: begin ct_len= 6'd6; ct_code=16'h0C00; end
                {5'd5, 2'd0}: begin ct_len= 6'd11; ct_code=16'h00E0; end
                {5'd5, 2'd1}: begin ct_len= 6'd10; ct_code=16'h0180; end
                {5'd5, 2'd2}: begin ct_len= 6'd9; ct_code=16'h0280; end
                {5'd5, 2'd3}: begin ct_len= 6'd7; ct_code=16'h0800; end
                {5'd6, 2'd0}: begin ct_len= 6'd13; ct_code=16'h0078; end
                {5'd6, 2'd1}: begin ct_len= 6'd11; ct_code=16'h00C0; end
                {5'd6, 2'd2}: begin ct_len= 6'd10; ct_code=16'h0140; end
                {5'd6, 2'd3}: begin ct_len= 6'd8; ct_code=16'h0400; end
                {5'd7, 2'd0}: begin ct_len= 6'd13; ct_code=16'h0058; end
                {5'd7, 2'd1}: begin ct_len= 6'd13; ct_code=16'h0070; end
                {5'd7, 2'd2}: begin ct_len= 6'd11; ct_code=16'h00A0; end
                {5'd7, 2'd3}: begin ct_len= 6'd9; ct_code=16'h0200; end
                {5'd8, 2'd0}: begin ct_len= 6'd13; ct_code=16'h0040; end
                {5'd8, 2'd1}: begin ct_len= 6'd13; ct_code=16'h0050; end
                {5'd8, 2'd2}: begin ct_len= 6'd13; ct_code=16'h0068; end
                {5'd8, 2'd3}: begin ct_len= 6'd10; ct_code=16'h0100; end
                {5'd9, 2'd0}: begin ct_len= 6'd14; ct_code=16'h003C; end
                {5'd9, 2'd1}: begin ct_len= 6'd14; ct_code=16'h0038; end
                {5'd9, 2'd2}: begin ct_len= 6'd13; ct_code=16'h0048; end
                {5'd9, 2'd3}: begin ct_len= 6'd11; ct_code=16'h0080; end
                {5'd10, 2'd0}: begin ct_len= 6'd14; ct_code=16'h002C; end
                {5'd10, 2'd1}: begin ct_len= 6'd14; ct_code=16'h0028; end
                {5'd10, 2'd2}: begin ct_len= 6'd14; ct_code=16'h0034; end
                {5'd10, 2'd3}: begin ct_len= 6'd13; ct_code=16'h0060; end
                {5'd11, 2'd0}: begin ct_len= 6'd15; ct_code=16'h001E; end
                {5'd11, 2'd1}: begin ct_len= 6'd15; ct_code=16'h001C; end
                {5'd11, 2'd2}: begin ct_len= 6'd14; ct_code=16'h0024; end
                {5'd11, 2'd3}: begin ct_len= 6'd14; ct_code=16'h0030; end
                {5'd12, 2'd0}: begin ct_len= 6'd15; ct_code=16'h0016; end
                {5'd12, 2'd1}: begin ct_len= 6'd15; ct_code=16'h0014; end
                {5'd12, 2'd2}: begin ct_len= 6'd15; ct_code=16'h001A; end
                {5'd12, 2'd3}: begin ct_len= 6'd14; ct_code=16'h0020; end
                {5'd13, 2'd0}: begin ct_len= 6'd16; ct_code=16'h000F; end
                {5'd13, 2'd1}: begin ct_len= 6'd15; ct_code=16'h0002; end
                {5'd13, 2'd2}: begin ct_len= 6'd15; ct_code=16'h0012; end
                {5'd13, 2'd3}: begin ct_len= 6'd15; ct_code=16'h0018; end
                {5'd14, 2'd0}: begin ct_len= 6'd16; ct_code=16'h000B; end
                {5'd14, 2'd1}: begin ct_len= 6'd16; ct_code=16'h000E; end
                {5'd14, 2'd2}: begin ct_len= 6'd16; ct_code=16'h000D; end
                {5'd14, 2'd3}: begin ct_len= 6'd15; ct_code=16'h0010; end
                {5'd15, 2'd0}: begin ct_len= 6'd16; ct_code=16'h0007; end
                {5'd15, 2'd1}: begin ct_len= 6'd16; ct_code=16'h000A; end
                {5'd15, 2'd2}: begin ct_len= 6'd16; ct_code=16'h0009; end
                {5'd15, 2'd3}: begin ct_len= 6'd16; ct_code=16'h000C; end
                {5'd16, 2'd0}: begin ct_len= 6'd16; ct_code=16'h0004; end
                {5'd16, 2'd1}: begin ct_len= 6'd16; ct_code=16'h0006; end
                {5'd16, 2'd2}: begin ct_len= 6'd16; ct_code=16'h0005; end
                {5'd16, 2'd3}: begin ct_len= 6'd16; ct_code=16'h0008; end
                default: begin ct_len= 6'd1; ct_code=16'h8000; end
            endcase
            2'd1: case ({total_coeffs, trailing_ones})
                {5'd0, 2'd0}: begin ct_len= 6'd2; ct_code=16'hC000; end
                {5'd1, 2'd0}: begin ct_len= 6'd6; ct_code=16'h2C00; end
                {5'd1, 2'd1}: begin ct_len= 6'd2; ct_code=16'h8000; end
                {5'd2, 2'd0}: begin ct_len= 6'd6; ct_code=16'h1C00; end
                {5'd2, 2'd1}: begin ct_len= 6'd5; ct_code=16'h3800; end
                {5'd2, 2'd2}: begin ct_len= 6'd3; ct_code=16'h6000; end
                {5'd3, 2'd0}: begin ct_len= 6'd7; ct_code=16'h0E00; end
                {5'd3, 2'd1}: begin ct_len= 6'd6; ct_code=16'h2800; end
                {5'd3, 2'd2}: begin ct_len= 6'd6; ct_code=16'h2400; end
                {5'd3, 2'd3}: begin ct_len= 6'd4; ct_code=16'h5000; end
                {5'd4, 2'd0}: begin ct_len= 6'd8; ct_code=16'h0700; end
                {5'd4, 2'd1}: begin ct_len= 6'd6; ct_code=16'h1800; end
                {5'd4, 2'd2}: begin ct_len= 6'd6; ct_code=16'h1400; end
                {5'd4, 2'd3}: begin ct_len= 6'd4; ct_code=16'h4000; end
                {5'd5, 2'd0}: begin ct_len= 6'd8; ct_code=16'h0400; end
                {5'd5, 2'd1}: begin ct_len= 6'd7; ct_code=16'h0C00; end
                {5'd5, 2'd2}: begin ct_len= 6'd7; ct_code=16'h0A00; end
                {5'd5, 2'd3}: begin ct_len= 6'd5; ct_code=16'h3000; end
                {5'd6, 2'd0}: begin ct_len= 6'd9; ct_code=16'h0380; end
                {5'd6, 2'd1}: begin ct_len= 6'd8; ct_code=16'h0600; end
                {5'd6, 2'd2}: begin ct_len= 6'd8; ct_code=16'h0500; end
                {5'd6, 2'd3}: begin ct_len= 6'd6; ct_code=16'h2000; end
                {5'd7, 2'd0}: begin ct_len= 6'd11; ct_code=16'h01E0; end
                {5'd7, 2'd1}: begin ct_len= 6'd9; ct_code=16'h0300; end
                {5'd7, 2'd2}: begin ct_len= 6'd9; ct_code=16'h0280; end
                {5'd7, 2'd3}: begin ct_len= 6'd6; ct_code=16'h1000; end
                {5'd8, 2'd0}: begin ct_len= 6'd11; ct_code=16'h0160; end
                {5'd8, 2'd1}: begin ct_len= 6'd11; ct_code=16'h01C0; end
                {5'd8, 2'd2}: begin ct_len= 6'd11; ct_code=16'h01A0; end
                {5'd8, 2'd3}: begin ct_len= 6'd7; ct_code=16'h0800; end
                {5'd9, 2'd0}: begin ct_len= 6'd12; ct_code=16'h00F0; end
                {5'd9, 2'd1}: begin ct_len= 6'd11; ct_code=16'h0140; end
                {5'd9, 2'd2}: begin ct_len= 6'd11; ct_code=16'h0120; end
                {5'd9, 2'd3}: begin ct_len= 6'd9; ct_code=16'h0200; end
                {5'd10, 2'd0}: begin ct_len= 6'd12; ct_code=16'h00B0; end
                {5'd10, 2'd1}: begin ct_len= 6'd12; ct_code=16'h00E0; end
                {5'd10, 2'd2}: begin ct_len= 6'd12; ct_code=16'h00D0; end
                {5'd10, 2'd3}: begin ct_len= 6'd11; ct_code=16'h0180; end
                {5'd11, 2'd0}: begin ct_len= 6'd12; ct_code=16'h0080; end
                {5'd11, 2'd1}: begin ct_len= 6'd12; ct_code=16'h00A0; end
                {5'd11, 2'd2}: begin ct_len= 6'd12; ct_code=16'h0090; end
                {5'd11, 2'd3}: begin ct_len= 6'd11; ct_code=16'h0100; end
                {5'd12, 2'd0}: begin ct_len= 6'd13; ct_code=16'h0078; end
                {5'd12, 2'd1}: begin ct_len= 6'd13; ct_code=16'h0070; end
                {5'd12, 2'd2}: begin ct_len= 6'd13; ct_code=16'h0068; end
                {5'd12, 2'd3}: begin ct_len= 6'd12; ct_code=16'h00C0; end
                {5'd13, 2'd0}: begin ct_len= 6'd13; ct_code=16'h0058; end
                {5'd13, 2'd1}: begin ct_len= 6'd13; ct_code=16'h0050; end
                {5'd13, 2'd2}: begin ct_len= 6'd13; ct_code=16'h0048; end
                {5'd13, 2'd3}: begin ct_len= 6'd13; ct_code=16'h0060; end
                {5'd14, 2'd0}: begin ct_len= 6'd13; ct_code=16'h0038; end
                {5'd14, 2'd1}: begin ct_len= 6'd14; ct_code=16'h002C; end
                {5'd14, 2'd2}: begin ct_len= 6'd13; ct_code=16'h0030; end
                {5'd14, 2'd3}: begin ct_len= 6'd13; ct_code=16'h0040; end
                {5'd15, 2'd0}: begin ct_len= 6'd14; ct_code=16'h0024; end
                {5'd15, 2'd1}: begin ct_len= 6'd14; ct_code=16'h0020; end
                {5'd15, 2'd2}: begin ct_len= 6'd14; ct_code=16'h0028; end
                {5'd15, 2'd3}: begin ct_len= 6'd13; ct_code=16'h0008; end
                {5'd16, 2'd0}: begin ct_len= 6'd14; ct_code=16'h001C; end
                {5'd16, 2'd1}: begin ct_len= 6'd14; ct_code=16'h0018; end
                {5'd16, 2'd2}: begin ct_len= 6'd14; ct_code=16'h0014; end
                {5'd16, 2'd3}: begin ct_len= 6'd14; ct_code=16'h0010; end
                default: begin ct_len= 6'd1; ct_code=16'h8000; end
            endcase
            2'd2: case ({total_coeffs, trailing_ones})
                {5'd0, 2'd0}: begin ct_len= 6'd4; ct_code=16'hF000; end
                {5'd1, 2'd0}: begin ct_len= 6'd6; ct_code=16'h3C00; end
                {5'd1, 2'd1}: begin ct_len= 6'd4; ct_code=16'hE000; end
                {5'd2, 2'd0}: begin ct_len= 6'd6; ct_code=16'h2C00; end
                {5'd2, 2'd1}: begin ct_len= 6'd5; ct_code=16'h7800; end
                {5'd2, 2'd2}: begin ct_len= 6'd4; ct_code=16'hD000; end
                {5'd3, 2'd0}: begin ct_len= 6'd6; ct_code=16'h2000; end
                {5'd3, 2'd1}: begin ct_len= 6'd5; ct_code=16'h6000; end
                {5'd3, 2'd2}: begin ct_len= 6'd5; ct_code=16'h7000; end
                {5'd3, 2'd3}: begin ct_len= 6'd4; ct_code=16'hC000; end
                {5'd4, 2'd0}: begin ct_len= 6'd7; ct_code=16'h1E00; end
                {5'd4, 2'd1}: begin ct_len= 6'd5; ct_code=16'h5000; end
                {5'd4, 2'd2}: begin ct_len= 6'd5; ct_code=16'h5800; end
                {5'd4, 2'd3}: begin ct_len= 6'd4; ct_code=16'hB000; end
                {5'd5, 2'd0}: begin ct_len= 6'd7; ct_code=16'h1600; end
                {5'd5, 2'd1}: begin ct_len= 6'd5; ct_code=16'h4000; end
                {5'd5, 2'd2}: begin ct_len= 6'd5; ct_code=16'h4800; end
                {5'd5, 2'd3}: begin ct_len= 6'd4; ct_code=16'hA000; end
                {5'd6, 2'd0}: begin ct_len= 6'd7; ct_code=16'h1200; end
                {5'd6, 2'd1}: begin ct_len= 6'd6; ct_code=16'h3800; end
                {5'd6, 2'd2}: begin ct_len= 6'd6; ct_code=16'h3400; end
                {5'd6, 2'd3}: begin ct_len= 6'd4; ct_code=16'h9000; end
                {5'd7, 2'd0}: begin ct_len= 6'd7; ct_code=16'h1000; end
                {5'd7, 2'd1}: begin ct_len= 6'd6; ct_code=16'h2800; end
                {5'd7, 2'd2}: begin ct_len= 6'd6; ct_code=16'h2400; end
                {5'd7, 2'd3}: begin ct_len= 6'd4; ct_code=16'h8000; end
                {5'd8, 2'd0}: begin ct_len= 6'd8; ct_code=16'h0F00; end
                {5'd8, 2'd1}: begin ct_len= 6'd7; ct_code=16'h1C00; end
                {5'd8, 2'd2}: begin ct_len= 6'd7; ct_code=16'h1A00; end
                {5'd8, 2'd3}: begin ct_len= 6'd5; ct_code=16'h6800; end
                {5'd9, 2'd0}: begin ct_len= 6'd8; ct_code=16'h0B00; end
                {5'd9, 2'd1}: begin ct_len= 6'd8; ct_code=16'h0E00; end
                {5'd9, 2'd2}: begin ct_len= 6'd7; ct_code=16'h1400; end
                {5'd9, 2'd3}: begin ct_len= 6'd6; ct_code=16'h3000; end
                {5'd10, 2'd0}: begin ct_len= 6'd9; ct_code=16'h0780; end
                {5'd10, 2'd1}: begin ct_len= 6'd8; ct_code=16'h0A00; end
                {5'd10, 2'd2}: begin ct_len= 6'd8; ct_code=16'h0D00; end
                {5'd10, 2'd3}: begin ct_len= 6'd7; ct_code=16'h1800; end
                {5'd11, 2'd0}: begin ct_len= 6'd9; ct_code=16'h0580; end
                {5'd11, 2'd1}: begin ct_len= 6'd9; ct_code=16'h0700; end
                {5'd11, 2'd2}: begin ct_len= 6'd8; ct_code=16'h0900; end
                {5'd11, 2'd3}: begin ct_len= 6'd8; ct_code=16'h0C00; end
                {5'd12, 2'd0}: begin ct_len= 6'd9; ct_code=16'h0400; end
                {5'd12, 2'd1}: begin ct_len= 6'd9; ct_code=16'h0500; end
                {5'd12, 2'd2}: begin ct_len= 6'd9; ct_code=16'h0680; end
                {5'd12, 2'd3}: begin ct_len= 6'd8; ct_code=16'h0800; end
                {5'd13, 2'd0}: begin ct_len= 6'd10; ct_code=16'h0340; end
                {5'd13, 2'd1}: begin ct_len= 6'd9; ct_code=16'h0380; end
                {5'd13, 2'd2}: begin ct_len= 6'd9; ct_code=16'h0480; end
                {5'd13, 2'd3}: begin ct_len= 6'd9; ct_code=16'h0600; end
                {5'd14, 2'd0}: begin ct_len= 6'd10; ct_code=16'h0240; end
                {5'd14, 2'd1}: begin ct_len= 6'd10; ct_code=16'h0300; end
                {5'd14, 2'd2}: begin ct_len= 6'd10; ct_code=16'h02C0; end
                {5'd14, 2'd3}: begin ct_len= 6'd10; ct_code = 16'h0280; end
                {5'd15, 2'd0}: begin ct_len= 6'd10; ct_code=16'h0140; end
                {5'd15, 2'd1}: begin ct_len= 6'd10; ct_code=16'h0200; end
                {5'd15, 2'd2}: begin ct_len= 6'd10; ct_code=16'h01C0; end
                {5'd15, 2'd3}: begin ct_len= 6'd10; ct_code=16'h0180; end
                {5'd16, 2'd0}: begin ct_len= 6'd10; ct_code=16'h0040; end
                {5'd16, 2'd1}: begin ct_len= 6'd10; ct_code=16'h0100; end
                {5'd16, 2'd2}: begin ct_len= 6'd10; ct_code=16'h00C0; end
                {5'd16, 2'd3}: begin ct_len= 6'd10; ct_code=16'h0080; end
                default: begin ct_len= 6'd1; ct_code=16'h8000; end
            endcase
            2'd3: begin
                ct_len = 6'd6;
                if (total_coeffs == 5'd0) begin
                    ct_code = {6'd3, 10'd0};
                end else begin
                    ct_code = {((({1'b0, total_coeffs} - 6'd1) << 2) | {4'd0, trailing_ones}), 10'd0};
                end
            end
        endcase
    end

    // =====================================================================
    // total_zeros ROM 
    // =====================================================================
    reg [3:0] tz_tc_r, tz_val_r;
    reg [5:0] tz_len;
    reg [8:0] tz_code;

    always @(*) begin
        tz_len  = 6'd1;
        tz_code = 9'h100;
        case (tz_tc_r)
            4'd1: case (tz_val_r)
                4'd0:  begin tz_len=6'd1; tz_code=9'h100; end // 1
                4'd1:  begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd2:  begin tz_len=6'd3; tz_code=9'h080; end // 010
                4'd3:  begin tz_len=6'd4; tz_code=9'h060; end // 0011
                4'd4:  begin tz_len=6'd4; tz_code=9'h040; end // 0010
                4'd5:  begin tz_len=6'd5; tz_code=9'h030; end // 00011
                4'd6:  begin tz_len=6'd5; tz_code=9'h020; end // 00010
                4'd7:  begin tz_len=6'd6; tz_code=9'h018; end // 000011
                4'd8:  begin tz_len=6'd6; tz_code=9'h010; end // 000010
                4'd9:  begin tz_len=6'd7; tz_code=9'h00c; end // 0000011
                4'd10: begin tz_len=6'd7; tz_code=9'h008; end // 0000010
                4'd11: begin tz_len=6'd8; tz_code=9'h006; end // 00000011
                4'd12: begin tz_len=6'd8; tz_code=9'h004; end // 00000010
                4'd13: begin tz_len=6'd9; tz_code=9'h003; end // 000000011
                4'd14: begin tz_len=6'd9; tz_code=9'h002; end // 000000010
                4'd15: begin tz_len=6'd9; tz_code=9'h001; end // 000000001
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd2: case (tz_val_r)
                4'd0:  begin tz_len=6'd3; tz_code=9'h1c0; end // 111
                4'd1:  begin tz_len=6'd3; tz_code=9'h180; end // 110
                4'd2:  begin tz_len=6'd3; tz_code=9'h140; end // 101
                4'd3:  begin tz_len=6'd3; tz_code=9'h100; end // 100
                4'd4:  begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd5:  begin tz_len=6'd4; tz_code=9'h0a0; end // 0101
                4'd6:  begin tz_len=6'd4; tz_code=9'h080; end // 0100
                4'd7:  begin tz_len=6'd4; tz_code=9'h060; end // 0011
                4'd8:  begin tz_len=6'd4; tz_code=9'h040; end // 0010
                4'd9:  begin tz_len=6'd5; tz_code=9'h030; end // 00011
                4'd10: begin tz_len=6'd5; tz_code=9'h020; end // 00010
                4'd11: begin tz_len=6'd6; tz_code=9'h018; end // 000011
                4'd12: begin tz_len=6'd6; tz_code=9'h010; end // 000010
                4'd13: begin tz_len=6'd6; tz_code=9'h008; end // 000001
                4'd14: begin tz_len=6'd6; tz_code=9'h000; end // 000000
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd3: case (tz_val_r)
                4'd0:  begin tz_len=6'd4; tz_code=9'h0a0; end // 0101
                4'd1:  begin tz_len=6'd3; tz_code=9'h1c0; end // 111
                4'd2:  begin tz_len=6'd3; tz_code=9'h180; end // 110
                4'd3:  begin tz_len=6'd3; tz_code=9'h140; end // 101
                4'd4:  begin tz_len=6'd4; tz_code=9'h080; end // 0100
                4'd5:  begin tz_len=6'd4; tz_code=9'h060; end // 0011
                4'd6:  begin tz_len=6'd3; tz_code=9'h100; end // 100
                4'd7:  begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd8:  begin tz_len=6'd4; tz_code=9'h040; end // 0010
                4'd9:  begin tz_len=6'd5; tz_code=9'h030; end // 00011
                4'd10: begin tz_len=6'd5; tz_code=9'h020; end // 00010
                4'd11: begin tz_len=6'd6; tz_code=9'h008; end // 000001
                4'd12: begin tz_len=6'd5; tz_code=9'h010; end // 00001
                4'd13: begin tz_len=6'd6; tz_code=9'h000; end // 000000
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd4: case (tz_val_r)
                4'd0:  begin tz_len=6'd5; tz_code=9'h030; end // 00011
                4'd1:  begin tz_len=6'd3; tz_code=9'h1c0; end // 111
                4'd2:  begin tz_len=6'd4; tz_code=9'h0a0; end // 0101
                4'd3:  begin tz_len=6'd4; tz_code=9'h080; end // 0100
                4'd4:  begin tz_len=6'd3; tz_code=9'h180; end // 110
                4'd5:  begin tz_len=6'd3; tz_code=9'h140; end // 101
                4'd6:  begin tz_len=6'd3; tz_code=9'h100; end // 100
                4'd7:  begin tz_len=6'd4; tz_code=9'h060; end // 0011
                4'd8:  begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd9:  begin tz_len=6'd4; tz_code=9'h040; end // 0010
                4'd10: begin tz_len=6'd5; tz_code=9'h020; end // 00010
                4'd11: begin tz_len=6'd5; tz_code=9'h010; end // 00001
                4'd12: begin tz_len=6'd5; tz_code=9'h000; end // 00000
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd5: case (tz_val_r)
                4'd0:  begin tz_len=6'd4; tz_code=9'h0a0; end // 0101
                4'd1:  begin tz_len=6'd4; tz_code=9'h080; end // 0100
                4'd2:  begin tz_len=6'd4; tz_code=9'h060; end // 0011
                4'd3:  begin tz_len=6'd3; tz_code=9'h1c0; end // 111
                4'd4:  begin tz_len=6'd3; tz_code=9'h180; end // 110
                4'd5:  begin tz_len=6'd3; tz_code=9'h140; end // 101
                4'd6:  begin tz_len=6'd3; tz_code=9'h100; end // 100
                4'd7:  begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd8:  begin tz_len=6'd4; tz_code=9'h040; end // 0010
                4'd9:  begin tz_len=6'd5; tz_code=9'h010; end // 00001
                4'd10: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                4'd11: begin tz_len=6'd5; tz_code=9'h000; end // 00000
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd6: case (tz_val_r)
                4'd0:  begin tz_len=6'd6; tz_code=9'h008; end // 000001
                4'd1:  begin tz_len=6'd5; tz_code=9'h010; end // 00001
                4'd2:  begin tz_len=6'd3; tz_code=9'h1c0; end // 111
                4'd3:  begin tz_len=6'd3; tz_code=9'h180; end // 110
                4'd4:  begin tz_len=6'd3; tz_code=9'h140; end // 101
                4'd5:  begin tz_len=6'd3; tz_code=9'h100; end // 100
                4'd6:  begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd7:  begin tz_len=6'd3; tz_code=9'h080; end // 010
                4'd8:  begin tz_len=6'd4; tz_code=9'h020; end // 0001
                4'd9:  begin tz_len=6'd3; tz_code=9'h040; end // 001
                4'd10: begin tz_len=6'd6; tz_code=9'h000; end // 000000
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd7: case (tz_val_r)
                4'd0: begin tz_len=6'd6; tz_code=9'h008; end // 000001
                4'd1: begin tz_len=6'd5; tz_code=9'h010; end // 00001
                4'd2: begin tz_len=6'd3; tz_code=9'h140; end // 101
                4'd3: begin tz_len=6'd3; tz_code=9'h100; end // 100
                4'd4: begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd5: begin tz_len=6'd2; tz_code=9'h180; end // 11
                4'd6: begin tz_len=6'd3; tz_code=9'h080; end // 010
                4'd7: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                4'd8: begin tz_len=6'd3; tz_code=9'h040; end // 001
                4'd9: begin tz_len=6'd6; tz_code=9'h000; end // 000000
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd8: case (tz_val_r)
                4'd0: begin tz_len=6'd6; tz_code=9'h008; end // 000001
                4'd1: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                4'd2: begin tz_len=6'd5; tz_code=9'h010; end // 00001
                4'd3: begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                4'd4: begin tz_len=6'd2; tz_code=9'h180; end // 11
                4'd5: begin tz_len=6'd2; tz_code=9'h100; end // 10
                4'd6: begin tz_len=6'd3; tz_code=9'h080; end // 010
                4'd7: begin tz_len=6'd3; tz_code=9'h040; end // 001
                4'd8: begin tz_len=6'd6; tz_code=9'h000; end // 000000
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd9: case (tz_val_r)
                4'd0: begin tz_len=6'd6; tz_code=9'h008; end // 000001
                4'd1: begin tz_len=6'd6; tz_code=9'h000; end // 000000
                4'd2: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                4'd3: begin tz_len=6'd2; tz_code=9'h180; end // 11
                4'd4: begin tz_len=6'd2; tz_code=9'h100; end // 10
                4'd5: begin tz_len=6'd3; tz_code=9'h040; end // 001
                4'd6: begin tz_len=6'd2; tz_code=9'h080; end // 01
                4'd7: begin tz_len=6'd5; tz_code=9'h010; end // 00001
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd10: case (tz_val_r)
                4'd0: begin tz_len=6'd5; tz_code=9'h010; end // 00001
                4'd1: begin tz_len=6'd5; tz_code=9'h000; end // 00000
                4'd2: begin tz_len=6'd3; tz_code=9'h040; end // 001
                4'd3: begin tz_len=6'd2; tz_code=9'h180; end // 11
                4'd4: begin tz_len=6'd2; tz_code=9'h100; end // 10
                4'd5: begin tz_len=6'd2; tz_code=9'h080; end // 01
                4'd6: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd11: case (tz_val_r)
                4'd0: begin tz_len=6'd4; tz_code=9'h000; end // 0000
                4'd1: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                4'd2: begin tz_len=6'd3; tz_code=9'h040; end // 001
                4'd3: begin tz_len=6'd3; tz_code=9'h080; end // 010
                4'd4: begin tz_len=6'd1; tz_code=9'h100; end // 1
                4'd5: begin tz_len=6'd3; tz_code=9'h0c0; end // 011
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd12: case (tz_val_r)
                4'd0: begin tz_len=6'd4; tz_code=9'h000; end // 0000
                4'd1: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                4'd2: begin tz_len=6'd2; tz_code=9'h080; end // 01
                4'd3: begin tz_len=6'd1; tz_code=9'h100; end // 1
                4'd4: begin tz_len=6'd3; tz_code=9'h040; end // 001
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd13: case (tz_val_r)
                4'd0: begin tz_len=6'd3; tz_code=9'h000; end // 000
                4'd1: begin tz_len=6'd3; tz_code=9'h040; end // 001
                4'd2: begin tz_len=6'd1; tz_code=9'h100; end // 1
                4'd3: begin tz_len=6'd2; tz_code=9'h080; end // 01
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd14: case (tz_val_r)
                4'd0: begin tz_len=6'd2; tz_code=9'h000; end // 00
                4'd1: begin tz_len=6'd2; tz_code=9'h080; end // 01
                4'd2: begin tz_len=6'd1; tz_code=9'h100; end // 1
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            4'd15: case (tz_val_r)
                4'd0: begin tz_len=6'd1; tz_code=9'h000; end // 0
                4'd1: begin tz_len=6'd1; tz_code=9'h100; end // 1
                default: begin tz_len=6'd1; tz_code=9'h000; end
            endcase
            default: begin tz_len=6'd1; tz_code=9'h100; end
        endcase

        // Override with chroma DC total_zeros tables
        if (is_chroma_dc) begin
            if (chroma_dc_422) begin
                // Table 9-9(b): 4:2:2 chroma DC total_zeros (maxNumCoeff=8)
                // From FFmpeg chroma422_dc_total_zeros_{bits,len}[7][8]
                // tz_tc_r = TotalCoeff (1-7), tz_val_r = total_zeros (0..7-tc)
                // Codes MSB-justified in 9 bits: code = bits << (9 - len)
                case (tz_tc_r[2:0])
                    3'd1: case (tz_val_r[2:0])
                        3'd0: begin tz_len=6'd1; tz_code=9'h100; end // 1
                        3'd1: begin tz_len=6'd3; tz_code=9'h080; end // 010
                        3'd2: begin tz_len=6'd3; tz_code=9'h0C0; end // 011
                        3'd3: begin tz_len=6'd4; tz_code=9'h040; end // 0010
                        3'd4: begin tz_len=6'd4; tz_code=9'h060; end // 0011
                        3'd5: begin tz_len=6'd4; tz_code=9'h020; end // 0001
                        3'd6: begin tz_len=6'd5; tz_code=9'h010; end // 00001
                        3'd7: begin tz_len=6'd5; tz_code=9'h000; end // 00000
                        default: begin tz_len=6'd1; tz_code=9'h100; end
                    endcase
                    3'd2: case (tz_val_r[2:0])
                        3'd0: begin tz_len=6'd3; tz_code=9'h000; end // 000
                        3'd1: begin tz_len=6'd2; tz_code=9'h080; end // 01
                        3'd2: begin tz_len=6'd3; tz_code=9'h040; end // 001
                        3'd3: begin tz_len=6'd3; tz_code=9'h100; end // 100
                        3'd4: begin tz_len=6'd3; tz_code=9'h140; end // 101
                        3'd5: begin tz_len=6'd3; tz_code=9'h180; end // 110
                        3'd6: begin tz_len=6'd3; tz_code=9'h1C0; end // 111
                        default: begin tz_len=6'd3; tz_code=9'h000; end
                    endcase
                    3'd3: case (tz_val_r[2:0])
                        3'd0: begin tz_len=6'd3; tz_code=9'h000; end // 000
                        3'd1: begin tz_len=6'd3; tz_code=9'h040; end // 001
                        3'd2: begin tz_len=6'd2; tz_code=9'h080; end // 01
                        3'd3: begin tz_len=6'd2; tz_code=9'h100; end // 10
                        3'd4: begin tz_len=6'd3; tz_code=9'h180; end // 110
                        3'd5: begin tz_len=6'd3; tz_code=9'h1C0; end // 111
                        default: begin tz_len=6'd3; tz_code=9'h000; end
                    endcase
                    3'd4: case (tz_val_r[2:0])
                        3'd0: begin tz_len=6'd3; tz_code=9'h180; end // 110
                        3'd1: begin tz_len=6'd2; tz_code=9'h000; end // 00
                        3'd2: begin tz_len=6'd2; tz_code=9'h080; end // 01
                        3'd3: begin tz_len=6'd2; tz_code=9'h100; end // 10
                        3'd4: begin tz_len=6'd3; tz_code=9'h1C0; end // 111
                        default: begin tz_len=6'd3; tz_code=9'h180; end
                    endcase
                    3'd5: case (tz_val_r[1:0])
                        2'd0: begin tz_len=6'd2; tz_code=9'h000; end // 00
                        2'd1: begin tz_len=6'd2; tz_code=9'h080; end // 01
                        2'd2: begin tz_len=6'd2; tz_code=9'h100; end // 10
                        2'd3: begin tz_len=6'd2; tz_code=9'h180; end // 11
                        default: begin tz_len=6'd2; tz_code=9'h000; end
                    endcase
                    3'd6: case (tz_val_r[1:0])
                        2'd0: begin tz_len=6'd2; tz_code=9'h000; end // 00
                        2'd1: begin tz_len=6'd2; tz_code=9'h080; end // 01
                        2'd2: begin tz_len=6'd1; tz_code=9'h100; end // 1
                        default: begin tz_len=6'd2; tz_code=9'h000; end
                    endcase
                    3'd7: case (tz_val_r[0])
                        1'd0: begin tz_len=6'd1; tz_code=9'h000; end // 0
                        1'd1: begin tz_len=6'd1; tz_code=9'h100; end // 1
                        default: begin tz_len=6'd1; tz_code=9'h000; end
                    endcase
                    default: begin tz_len=6'd1; tz_code=9'h100; end
                endcase
            end else begin
                // Table 9-9(a): 4:2:0 chroma DC total_zeros (maxNumCoeff=4)
                case (tz_tc_r[1:0])
                    2'd1: case (tz_val_r[1:0])
                        2'd0: begin tz_len=6'd1; tz_code=9'h100; end // 1
                        2'd1: begin tz_len=6'd2; tz_code=9'h080; end // 01
                        2'd2: begin tz_len=6'd3; tz_code=9'h040; end // 001
                        2'd3: begin tz_len=6'd3; tz_code=9'h000; end // 000
                        default: begin tz_len=6'd1; tz_code=9'h100; end
                    endcase
                    2'd2: case (tz_val_r[1:0])
                        2'd0: begin tz_len=6'd1; tz_code=9'h100; end // 1
                        2'd1: begin tz_len=6'd2; tz_code=9'h080; end // 01
                        2'd2: begin tz_len=6'd2; tz_code=9'h000; end // 00
                        default: begin tz_len=6'd1; tz_code=9'h100; end
                    endcase
                    2'd3: case (tz_val_r[1:0])
                        2'd0: begin tz_len=6'd1; tz_code=9'h100; end // 1
                        2'd1: begin tz_len=6'd1; tz_code=9'h000; end // 0
                        default: begin tz_len=6'd1; tz_code=9'h100; end
                    endcase
                    default: begin tz_len=6'd1; tz_code=9'h100; end
                endcase
            end
        end
    end

    // =====================================================================
    // run_before ROM 
    // Output: MSB-justified 32-bit code and length
    // =====================================================================
    reg [3:0] rb_zl_r, rb_run_r;
    reg [5:0] rb_len;
    reg [31:0] rb_code;

    always @(*) begin
        rb_len  = 6'd1;
        rb_code = 32'h80000000;
        if (rb_zl_r >= 4'd7) begin
            case (rb_run_r)
                4'd0: begin rb_len=6'd3; rb_code=32'hE0000000; end
                4'd1: begin rb_len=6'd3; rb_code=32'hC0000000; end
                4'd2: begin rb_len=6'd3; rb_code=32'hA0000000; end
                4'd3: begin rb_len=6'd3; rb_code=32'h80000000; end
                4'd4: begin rb_len=6'd3; rb_code=32'h60000000; end
                4'd5: begin rb_len=6'd3; rb_code=32'h40000000; end
                4'd6: begin rb_len=6'd3; rb_code=32'h20000000; end
                4'd7: begin rb_len=6'd4; rb_code=32'h10000000; end
                4'd8: begin rb_len=6'd5; rb_code=32'h08000000; end
                4'd9: begin rb_len=6'd6; rb_code=32'h04000000; end
                4'd10: begin rb_len=6'd7; rb_code=32'h02000000; end
                4'd11: begin rb_len=6'd8; rb_code=32'h01000000; end
                4'd12: begin rb_len=6'd9; rb_code=32'h00800000; end
                4'd13: begin rb_len=6'd10; rb_code=32'h00400000; end
                4'd14: begin rb_len=6'd11; rb_code=32'h00200000; end
                default: begin rb_len=6'd11; rb_code=32'h00200000; end
            endcase
        end else begin
            case (rb_zl_r)
                4'd1: case (rb_run_r)
                    4'd0: begin rb_len=6'd1; rb_code=32'h80000000; end
                    4'd1: begin rb_len=6'd1; rb_code=32'h00000000; end
                    default: begin rb_len=6'd1; rb_code=32'h00000000; end
                endcase
                4'd2: case (rb_run_r)
                    4'd0: begin rb_len=6'd1; rb_code=32'h80000000; end
                    4'd1: begin rb_len=6'd2; rb_code=32'h40000000; end
                    4'd2: begin rb_len=6'd2; rb_code=32'h00000000; end
                    default: begin rb_len=6'd1; rb_code=32'h00000000; end
                endcase
                4'd3: case (rb_run_r)
                    4'd0: begin rb_len=6'd2; rb_code=32'hC0000000; end
                    4'd1: begin rb_len=6'd2; rb_code=32'h80000000; end
                    4'd2: begin rb_len=6'd2; rb_code=32'h40000000; end
                    4'd3: begin rb_len=6'd2; rb_code=32'h00000000; end
                    default: begin rb_len=6'd1; rb_code=32'h00000000; end
                endcase
                4'd4: case (rb_run_r)
                    4'd0: begin rb_len=6'd2; rb_code=32'hC0000000; end
                    4'd1: begin rb_len=6'd2; rb_code=32'h80000000; end
                    4'd2: begin rb_len=6'd2; rb_code=32'h40000000; end
                    4'd3: begin rb_len=6'd3; rb_code=32'h20000000; end
                    4'd4: begin rb_len=6'd3; rb_code=32'h00000000; end
                    default: begin rb_len=6'd1; rb_code=32'h00000000; end
                endcase
                4'd5: case (rb_run_r)
                    4'd0: begin rb_len=6'd2; rb_code=32'hC0000000; end
                    4'd1: begin rb_len=6'd2; rb_code=32'h80000000; end
                    4'd2: begin rb_len=6'd3; rb_code=32'h60000000; end
                    4'd3: begin rb_len=6'd3; rb_code=32'h40000000; end
                    4'd4: begin rb_len=6'd3; rb_code=32'h20000000; end
                    4'd5: begin rb_len=6'd3; rb_code=32'h00000000; end
                    default: begin rb_len=6'd1; rb_code=32'h00000000; end
                endcase
                4'd6: case (rb_run_r)
                    4'd0: begin rb_len=6'd2; rb_code=32'hC0000000; end
                    4'd1: begin rb_len=6'd3; rb_code=32'h00000000; end
                    4'd2: begin rb_len=6'd3; rb_code=32'h20000000; end
                    4'd3: begin rb_len=6'd3; rb_code=32'h60000000; end
                    4'd4: begin rb_len=6'd3; rb_code=32'h40000000; end
                    4'd5: begin rb_len=6'd3; rb_code=32'hA0000000; end
                    4'd6: begin rb_len=6'd3; rb_code=32'h80000000; end
                    default: begin rb_len=6'd1; rb_code=32'h00000000; end
                endcase
                default: begin rb_len=6'd1; rb_code=32'h80000000; end
            endcase
        end
    end

    // =====================================================================
    // Level VLC encoder (combinational)
    // Driven by lev_lcode_r / lev_suflen_r (registered), outputs lev_out_*
    // Code is MSB-justified in 32 bits.
    // =====================================================================
    reg [15:0] lev_lcode_r;
    reg [3:0]  lev_suflen_r;

    reg [63:0] lev_out_data;
    reg [6:0]  lev_out_bits;
    reg [15:0] lev_prefix;
    reg [5:0]  lev_prefix_len;
    reg [63:0] lev_suffix_bits;
    reg [5:0]  lev_escape_prefix;
    reg [31:0] lev_emit_hi_bits;
    reg [31:0] lev_emit_lo_bits;
    reg [5:0]  lev_emit_lo_count;

    always @(*) begin
        lev_out_data = 64'd0;
        lev_out_bits = 7'd1;
        lev_prefix = 16'd0;
        lev_prefix_len = 6'd0;
        lev_suffix_bits = 64'd0;
        lev_escape_prefix = 6'd15;
        lev_emit_hi_bits = 32'd0;
        lev_emit_lo_bits = 32'd0;
        lev_emit_lo_count = 6'd0;

        lev_prefix = lev_lcode_r >> lev_suflen_r;
        if (lev_suflen_r == 4'd0 && lev_lcode_r < 16'd14) begin
            lev_out_bits = {2'd0, lev_lcode_r[3:0]} + 6'd1;
            lev_out_data = 64'd1;
        end else if (lev_suflen_r == 4'd0 && lev_lcode_r < 16'd30) begin
            lev_out_bits = 7'd19;
            lev_out_data = ((64'd1 << 4) + ({48'd0, lev_lcode_r} - 64'd14)) & 64'h1F;
        end else if (lev_suflen_r != 4'd0 && lev_prefix == 16'd14) begin
            lev_out_bits = 7'd15 + {3'd0, lev_suflen_r};
            lev_suffix_bits = (64'd1 << lev_suflen_r)
                            + ({48'd0, lev_lcode_r} & ((64'd1 << lev_suflen_r) - 64'd1));
            lev_out_data = lev_suffix_bits;
        end else if (lev_prefix < 16'd14) begin
            lev_prefix_len = {1'b0, lev_prefix[4:0]};
            lev_out_bits = {1'b0, lev_prefix_len} + 7'd1 + {3'd0, lev_suflen_r};
            lev_suffix_bits = (lev_suflen_r == 4'd0) ? 64'd1 :
                              ((64'd1 << lev_suflen_r)
                               + ({48'd0, lev_lcode_r} & ((64'd1 << lev_suflen_r) - 64'd1)));
            lev_out_data = lev_suffix_bits;
        end else begin
            lev_suffix_bits = {48'd0, lev_lcode_r} - (64'd15 << lev_suflen_r);
            if (lev_suflen_r == 4'd0)
                lev_suffix_bits = lev_suffix_bits - 64'd15;
            while ((lev_escape_prefix < 6'd17) &&
                   (lev_suffix_bits >= (64'd1 << (lev_escape_prefix - 6'd3)))) begin
                lev_suffix_bits = lev_suffix_bits - (64'd1 << (lev_escape_prefix - 6'd3));
                lev_escape_prefix = lev_escape_prefix + 6'd1;
            end
            lev_out_bits = {1'b0, ((lev_escape_prefix << 1) - 6'd2)};
            lev_out_data = (64'd1 << (lev_escape_prefix - 6'd3))
                         + (lev_suffix_bits & ((64'd1 << (lev_escape_prefix - 6'd3)) - 64'd1));
        end

        if (lev_out_bits > 7'd32) begin
            lev_emit_hi_bits = lev_out_data >> (lev_out_bits - 7'd32);
            lev_emit_lo_count = lev_out_bits - 7'd32;
            lev_emit_lo_bits = lev_out_data & ((64'd1 << lev_emit_lo_count) - 64'd1);
        end else begin
            lev_emit_hi_bits = lev_out_data[31:0] << (7'd32 - lev_out_bits);
        end
    end

    // =====================================================================
    // Main FSM
    // =====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            bits_valid   <= 1'b0;
            bits_out     <= 32'd0;
            bits_count   <= 6'd0;
            nz_cnt       <= 5'd0;
            idx          <= 5'd0;
            zero_run_cnt <= 4'd0;
            total_zeros_r<= 4'd0;
            zeros_left   <= 4'd0;
            suffix_len   <= 4'd0;
            tz_tc_r      <= 4'd0;
            tz_val_r     <= 4'd0;
            rb_zl_r      <= 4'd0;
            rb_run_r     <= 4'd0;
            lev_lcode_r  <= 16'd0;
            lev_suflen_r <= 4'd0;
        end else begin
            done       <= 1'b0;
            bits_valid <= 1'b0;

            // verilator lint_off BLKSEQ
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_COEFF_TOKEN;
                    end
                end

                // Emit coeff_token
                S_COEFF_TOKEN: begin
                    bits_out   <= {ct_code, 16'd0};
                    bits_count <= ct_len;
                    bits_valid <= 1'b1;


                    if (total_coeffs == 5'd0) begin
                        state <= S_DONE;
                    end else begin
                        state        <= S_COLLECT;
                        idx          <= {1'b0, last_nonzero_idx};
                        nz_cnt       <= 5'd0;
                        zero_run_cnt <= 4'd0;
                        total_zeros_r<= 4'd0;
                    end
                end

                // Collect non-zero coefficients in reverse scan order.
                S_COLLECT: begin
                    cur_val = $signed(scan_flat[idx[3:0]*16 +: 16]);
                    if (nz_cnt < total_coeffs) begin
                        if (cur_val != 16'sd0) begin
                            nz_val[nz_cnt[3:0]] <= cur_val;
                            if (nz_cnt > 5'd0)
                                nz_run[nz_cnt[3:0] - 4'd1] <= zero_run_cnt;
                            nz_cnt       <= nz_cnt + 5'd1;
                            zero_run_cnt <= 4'd0;
                        end else begin
                            zero_run_cnt <= zero_run_cnt + 4'd1;
                        end
                    end

                    if (idx == 5'd0 || nz_cnt >= total_coeffs) begin
                        total_zeros_r <= (last_nonzero_idx + 4'd1) - total_coeffs[3:0];
                        state <= S_TRAIL_SIGNS;
                    end else begin
                        idx <= idx - 5'd1;
                    end
                end

                // Emit trailing one signs
                S_TRAIL_SIGNS: begin
                    if (trailing_ones > 2'd0) begin
                        bits_count <= {4'd0, trailing_ones};
                        bits_valid <= 1'b1;
                        bits_out   <= 32'd0;
                        if (trailing_ones >= 2'd1)
                            bits_out[31] <= nz_val[0][15];
                        if (trailing_ones >= 2'd2)
                            bits_out[30] <= nz_val[1][15];
                        if (trailing_ones == 2'd3)
                            bits_out[29] <= nz_val[2][15];
                    end
                    suffix_len <= (total_coeffs > 5'd10 && trailing_ones < 2'd3) ? 4'd1 : 4'd0;
                    idx <= {3'd0, trailing_ones};

                    if ({3'd0, trailing_ones} < total_coeffs) begin
                        state <= S_LEV_SETUP;
                    end else begin
                        state <= S_TZ_SETUP;
                    end
                end

                S_LEV_SETUP: begin
                    if (idx < total_coeffs) begin
                        cur_val  = nz_val[idx[3:0]];
                        cur_sign = cur_val[15];
                        cur_abs  = cur_sign ? (~cur_val + 16'd1) : cur_val;

                        if (idx == {3'd0, trailing_ones} && trailing_ones < 2'd3)
                            level_code_w = (cur_abs - 16'd2) * 16'd2;
                        else
                            level_code_w = (cur_abs - 16'd1) * 16'd2;

                        if (cur_sign)
                            level_code_w = level_code_w + 16'd1;

                        lev_lcode_r  <= level_code_w;
                        lev_suflen_r <= suffix_len;

                        state <= S_LEV_EMIT;
                    end else begin
                        state <= S_TZ_SETUP;
                    end
                end

                S_LEV_EMIT: begin
                    bits_out   <= lev_emit_hi_bits;
                    bits_count <= (lev_out_bits > 7'd32) ? 6'd32 : lev_out_bits[5:0];
                    bits_valid <= 1'b1;

                    if (lev_out_bits > 7'd32) begin
                        state <= S_LEV_EMIT_LO;
                    end else begin

                        cur_val  = nz_val[idx[3:0]];
                        cur_sign = cur_val[15];
                        cur_abs  = cur_sign ? (~cur_val + 16'd1) : cur_val;

                        begin : update_suffix_len
                            reg [3:0] next_suffix_len;
                            next_suffix_len = suffix_len;
                            if (next_suffix_len == 4'd0)
                                next_suffix_len = 4'd1;
                            if ((cur_abs > ({12'd0, 4'd3} << (next_suffix_len - 4'd1))) &&
                                (next_suffix_len < 4'd6))
                                next_suffix_len = next_suffix_len + 4'd1;
                            suffix_len <= next_suffix_len;
                        end

                        idx <= idx + 5'd1;

                        if (idx + 5'd1 < total_coeffs)
                            state <= S_LEV_SETUP;
                        else
                            state <= S_TZ_SETUP;
                    end
                end

                S_LEV_EMIT_LO: begin
                    bits_out   <= lev_emit_lo_bits << (6'd32 - lev_emit_lo_count);
                    bits_count <= lev_emit_lo_count;
                    bits_valid <= 1'b1;

                    cur_val  = nz_val[idx[3:0]];
                    cur_sign = cur_val[15];
                    cur_abs  = cur_sign ? (~cur_val + 16'd1) : cur_val;

                    begin : update_suffix_len_lo
                        reg [3:0] next_suffix_len;
                        next_suffix_len = suffix_len;
                        if (next_suffix_len == 4'd0)
                            next_suffix_len = 4'd1;
                        if ((cur_abs > ({12'd0, 4'd3} << (next_suffix_len - 4'd1))) &&
                            (next_suffix_len < 4'd6))
                            next_suffix_len = next_suffix_len + 4'd1;
                        suffix_len <= next_suffix_len;
                    end

                    idx <= idx + 5'd1;

                    if (idx + 5'd1 < total_coeffs)
                        state <= S_LEV_SETUP;
                    else
                        state <= S_TZ_SETUP;
                end

                S_TZ_SETUP: begin
                    // maxNumCoeff: 4 for chroma DC 4:2:0, 8 for chroma DC 4:2:2, 15 for chroma AC, 16 for luma
                    if ((is_chroma_dc && total_coeffs < (chroma_dc_422 ? 5'd8 : 5'd4)) ||
                        (is_chroma_ac && total_coeffs < 5'd15) ||
                        (!is_chroma_dc && !is_chroma_ac && total_coeffs < 5'd16)) begin
                        tz_tc_r  <= total_coeffs[3:0];
                        tz_val_r <= total_zeros_r;
                        state    <= S_TZ_EMIT;
                    end else begin
                        idx        <= 5'd0;
                        zeros_left <= 4'd0;
                        state      <= S_DONE;
                    end
                end

                S_TZ_EMIT: begin
                    bits_out   <= {tz_code, 23'd0};
                    bits_count <= tz_len;
                    bits_valid <= 1'b1;


                    idx        <= 5'd0;
                    zeros_left <= total_zeros_r;

                    if (total_coeffs > 5'd1 && total_zeros_r > 4'd0)
                        state <= S_RB_SETUP;
                    else
                        state <= S_DONE;
                end

                S_RB_SETUP: begin
                    if (idx < (total_coeffs - 5'd1) && zeros_left > 4'd0) begin
                        rb_zl_r  <= zeros_left;
                        rb_run_r <= nz_run[idx[3:0]];
                        state    <= S_RB_EMIT;
                    end else begin
                        state <= S_DONE;
                    end
                end

                S_RB_EMIT: begin
                    bits_out   <= rb_code;
                    bits_count <= rb_len;
                    bits_valid <= 1'b1;

                    zeros_left <= zeros_left - rb_run_r;
                    idx        <= idx + 5'd1;

                    if ((idx + 5'd1) < (total_coeffs - 5'd1) && (zeros_left - rb_run_r) > 4'd0)
                        state <= S_RB_SETUP;
                    else
                        state <= S_DONE;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
            // verilator lint_on BLKSEQ
        end
    end

endmodule
