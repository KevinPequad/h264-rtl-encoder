/*
 * parse_422.c -- Minimal H.264 bitstream parser for High 4:2:2 profile
 *
 * Purpose: Find exactly where an RTL encoder's bitstream diverges from
 *          what the decoder expects, by parsing each field and printing it.
 *
 * Compile:  gcc -o parse_422 parse_422.c -lm
 * Run:      ./parse_422
 *
 * Hardcoded to open "bright_422.h264" in the current directory.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

/* ================================================================
 * Bitstream reader (operates on de-emulation-prevented byte buffer)
 * ================================================================ */

static uint8_t *bs_buf;
static int      bs_len;
static int      bs_bit_pos;  /* current bit position */

static int bs_eof(void) {
    return bs_bit_pos >= bs_len * 8;
}

static uint32_t bs_read_bits(int n) {
    uint32_t val = 0;
    for (int i = 0; i < n; i++) {
        if (bs_bit_pos >= bs_len * 8) {
            fprintf(stderr, "ERROR: read past end of buffer at bit %d\n", bs_bit_pos);
            return val;
        }
        int byte_idx = bs_bit_pos >> 3;
        int bit_idx  = 7 - (bs_bit_pos & 7);
        val = (val << 1) | ((bs_buf[byte_idx] >> bit_idx) & 1);
        bs_bit_pos++;
    }
    return val;
}

static uint32_t bs_peek_bits(int n) {
    int saved = bs_bit_pos;
    uint32_t val = bs_read_bits(n);
    bs_bit_pos = saved;
    return val;
}

static uint32_t bs_read_ue(void) {
    int leading_zeros = 0;
    while (!bs_eof() && bs_read_bits(1) == 0)
        leading_zeros++;
    if (leading_zeros > 30) {
        fprintf(stderr, "ERROR: UE(v) leading zeros = %d (too many) at bit %d\n",
                leading_zeros, bs_bit_pos);
        return 0;
    }
    uint32_t val = (1 << leading_zeros) - 1;
    if (leading_zeros > 0)
        val += bs_read_bits(leading_zeros);
    return val;
}

static int32_t bs_read_se(void) {
    uint32_t code_num = bs_read_ue();
    int32_t val = (code_num + 1) / 2;
    if ((code_num & 1) == 0)
        val = -val;
    return val;
}

/* ================================================================
 * NAL unit finder (handles emulation prevention)
 * ================================================================ */

static uint8_t *file_buf;
static int      file_len;

/* Find start codes and return pointer + length of NAL (RBSP with EP removed) */
typedef struct {
    int      nal_type;
    int      nal_ref_idc;
    uint8_t *rbsp;
    int      rbsp_len;
    int      file_offset;  /* byte offset in file where NAL header starts */
} nal_unit_t;

static int find_start_code(int offset) {
    for (int i = offset; i < file_len - 3; i++) {
        if (file_buf[i] == 0 && file_buf[i+1] == 0 && file_buf[i+2] == 1)
            return i + 3;
        if (file_buf[i] == 0 && file_buf[i+1] == 0 && file_buf[i+2] == 0 &&
            i + 3 < file_len && file_buf[i+3] == 1)
            return i + 4;
    }
    return -1;
}

static int find_next_start_code(int offset) {
    for (int i = offset; i < file_len - 2; i++) {
        if (file_buf[i] == 0 && file_buf[i+1] == 0 &&
            (file_buf[i+2] == 1 || (file_buf[i+2] == 0 && i + 3 < file_len && file_buf[i+3] == 1)))
            return i;
    }
    return file_len;
}

/* Remove emulation prevention bytes (0x00 0x00 0x03 -> 0x00 0x00) */
static uint8_t *remove_ep(const uint8_t *src, int src_len, int *out_len) {
    uint8_t *dst = malloc(src_len);
    int j = 0;
    for (int i = 0; i < src_len; i++) {
        if (i + 2 < src_len && src[i] == 0 && src[i+1] == 0 && src[i+2] == 3) {
            dst[j++] = 0;
            dst[j++] = 0;
            i += 2; /* skip the 0x03 */
        } else {
            dst[j++] = src[i];
        }
    }
    *out_len = j;
    return dst;
}

static nal_unit_t parse_nal_at(int offset) {
    nal_unit_t nal;
    memset(&nal, 0, sizeof(nal));
    nal.file_offset = offset;

    int end = find_next_start_code(offset);
    int raw_len = end - offset;

    uint8_t hdr = file_buf[offset];
    nal.nal_ref_idc = (hdr >> 5) & 3;
    nal.nal_type = hdr & 0x1F;

    /* RBSP = NAL bytes after header, with EP bytes removed */
    nal.rbsp = remove_ep(file_buf + offset + 1, raw_len - 1, &nal.rbsp_len);
    return nal;
}

/* ================================================================
 * CAVLC VLC tables (for coeff_token parsing by bit-matching)
 * ================================================================
 * Instead of hardcoding every entry, we implement the decoder's
 * bit-pattern-matching approach.
 */

/* coeff_token: returns total_coeffs and trailing_ones.
 * nC selects the table:
 *   nC >= 0: luma / chroma AC (standard tables 0..3)
 *   nC == -1: 4:2:0 chroma DC
 *   nC == -2: 4:2:2 chroma DC
 */

typedef struct {
    int total_coeffs;
    int trailing_ones;
    int bits_consumed;
} coeff_token_t;

/*
 * Table-based coeff_token decoder.
 * We build lookup tables from the H.264 spec (Table 9-5) and
 * the FFmpeg chroma 4:2:2 DC table.
 *
 * For simplicity, we use a brute-force approach: try all (TC, T1) combos,
 * encode each one, and check if the bitstream matches. This is slow but
 * correct and easy to validate.
 */

/* Encode a coeff_token into {code, len} for a given nC index */
typedef struct { uint16_t code; int len; } vlc_entry_t;

/* nC=0..1 table (Table 9-5, column nC=0..1) */
static const vlc_entry_t ct_table_0[][4] = {
    /* TC=0 */  {{0x0001, 1}, {0,0}, {0,0}, {0,0}},
    /* TC=1 */  {{0x0005, 6}, {0x0001, 2}, {0,0}, {0,0}},
    /* TC=2 */  {{0x0007, 8}, {0x0004, 6}, {0x0001, 3}, {0,0}},
    /* TC=3 */  {{0x0007, 9}, {0x0006, 8}, {0x0005, 7}, {0x0003, 5}},
    /* TC=4 */  {{0x0007,10}, {0x0006, 9}, {0x0005, 8}, {0x0003, 6}},
    /* TC=5 */  {{0x0007,11}, {0x0006,10}, {0x0005, 9}, {0x0004, 7}},
    /* TC=6 */  {{0x000F,13}, {0x0006,11}, {0x0005,10}, {0x0004, 8}},
    /* TC=7 */  {{0x000B,13}, {0x000E,13}, {0x0005,11}, {0x0004, 9}},
    /* TC=8 */  {{0x0008,13}, {0x000A,13}, {0x000D,13}, {0x0004,10}},
    /* TC=9 */  {{0x000F,14}, {0x000E,14}, {0x0009,13}, {0x0004,11}},
    /* TC=10 */ {{0x000B,14}, {0x000A,14}, {0x000D,14}, {0x000C,13}},
    /* TC=11 */ {{0x000F,15}, {0x000E,15}, {0x0009,14}, {0x000C,14}},
    /* TC=12 */ {{0x000B,15}, {0x000A,15}, {0x000D,15}, {0x0008,14}},
    /* TC=13 */ {{0x000F,16}, {0x0001,15}, {0x0009,15}, {0x000C,15}},
    /* TC=14 */ {{0x000B,16}, {0x000E,16}, {0x000D,16}, {0x0008,15}},
    /* TC=15 */ {{0x0007,16}, {0x000A,16}, {0x0009,16}, {0x000C,16}},
    /* TC=16 */ {{0x0004,16}, {0x0006,16}, {0x0005,16}, {0x0008,16}},
};

/* nC=2..3 table */
static const vlc_entry_t ct_table_1[][4] = {
    /* TC=0 */  {{0x0003, 2}, {0,0}, {0,0}, {0,0}},
    /* TC=1 */  {{0x000B, 6}, {0x0002, 2}, {0,0}, {0,0}},
    /* TC=2 */  {{0x0007, 6}, {0x0007, 5}, {0x0003, 3}, {0,0}},
    /* TC=3 */  {{0x0007, 7}, {0x000A, 6}, {0x0009, 6}, {0x0005, 4}},
    /* TC=4 */  {{0x0007, 8}, {0x0006, 6}, {0x0005, 6}, {0x0004, 4}},
    /* TC=5 */  {{0x0004, 8}, {0x0006, 7}, {0x0005, 7}, {0x0006, 5}},
    /* TC=6 */  {{0x0007, 9}, {0x0006, 8}, {0x0005, 8}, {0x0008, 6}},
    /* TC=7 */  {{0x000F,11}, {0x0006, 9}, {0x0005, 9}, {0x0004, 6}},
    /* TC=8 */  {{0x000B,11}, {0x000E,11}, {0x000D,11}, {0x0004, 7}},
    /* TC=9 */  {{0x000F,12}, {0x000A,11}, {0x0009,11}, {0x0004, 9}},
    /* TC=10 */ {{0x000B,12}, {0x000E,12}, {0x000D,12}, {0x000C,11}},
    /* TC=11 */ {{0x0008,12}, {0x000A,12}, {0x0009,12}, {0x0008,11}},
    /* TC=12 */ {{0x000F,13}, {0x000E,13}, {0x000D,13}, {0x000C,12}},
    /* TC=13 */ {{0x000B,13}, {0x000A,13}, {0x0009,13}, {0x000C,13}},
    /* TC=14 */ {{0x0007,13}, {0x000B,14}, {0x0006,13}, {0x0008,13}},
    /* TC=15 */ {{0x0009,14}, {0x0008,14}, {0x000A,14}, {0x0001,13}},
    /* TC=16 */ {{0x0007,14}, {0x0006,14}, {0x0005,14}, {0x0004,14}},
};

/* nC=4..7 table */
static const vlc_entry_t ct_table_2[][4] = {
    /* TC=0 */  {{0x000F, 4}, {0,0}, {0,0}, {0,0}},
    /* TC=1 */  {{0x000F, 6}, {0x000E, 4}, {0,0}, {0,0}},
    /* TC=2 */  {{0x000B, 6}, {0x000F, 5}, {0x000D, 4}, {0,0}},
    /* TC=3 */  {{0x0008, 6}, {0x000C, 5}, {0x000E, 5}, {0x000C, 4}},
    /* TC=4 */  {{0x000F, 7}, {0x000A, 5}, {0x000B, 5}, {0x000B, 4}},
    /* TC=5 */  {{0x000B, 7}, {0x0008, 5}, {0x0009, 5}, {0x000A, 4}},
    /* TC=6 */  {{0x0009, 7}, {0x000E, 6}, {0x000D, 6}, {0x0009, 4}},
    /* TC=7 */  {{0x0008, 7}, {0x000A, 6}, {0x0009, 6}, {0x0008, 4}},
    /* TC=8 */  {{0x000F, 8}, {0x000E, 7}, {0x000D, 7}, {0x000D, 5}},
    /* TC=9 */  {{0x000B, 8}, {0x000E, 8}, {0x000A, 7}, {0x000C, 6}},
    /* TC=10 */ {{0x000F, 9}, {0x000A, 8}, {0x000D, 8}, {0x000C, 7}},
    /* TC=11 */ {{0x000B, 9}, {0x000E, 9}, {0x0009, 8}, {0x000C, 8}},
    /* TC=12 */ {{0x0008, 9}, {0x000A, 9}, {0x000D, 9}, {0x0008, 8}},
    /* TC=13 */ {{0x000D,10}, {0x0007, 9}, {0x0009, 9}, {0x000C, 9}},
    /* TC=14 */ {{0x0009,10}, {0x000C,10}, {0x000B,10}, {0x000A,10}},
    /* TC=15 */ {{0x0005,10}, {0x0008,10}, {0x0007,10}, {0x0006,10}},
    /* TC=16 */ {{0x0001,10}, {0x0004,10}, {0x0003,10}, {0x0002,10}},
};

/* nC >= 8: fixed 6-bit codes */
/* TC=0: code=3 (000011), TC>0: code = (TC-1)*4 + T1 */

/* 4:2:0 chroma DC (nC=-1, Table 9-5, last column) */
static const vlc_entry_t ct_table_chroma_dc_420[][4] = {
    /* TC=0 */ {{0x0001, 2}, {0,0}, {0,0}, {0,0}},
    /* TC=1 */ {{0x0007, 6}, {0x0001, 1}, {0,0}, {0,0}},
    /* TC=2 */ {{0x0004, 6}, {0x0006, 6}, {0x0001, 3}, {0,0}},
    /* TC=3 */ {{0x0003, 6}, {0x0003, 7}, {0x0002, 7}, {0x0005, 6}},
    /* TC=4 */ {{0x0002, 6}, {0x0003, 8}, {0x0002, 8}, {0x0000, 7}},
};

/* 4:2:2 chroma DC (nC=-2, maxNumCoeff=8) from FFmpeg */
static const vlc_entry_t ct_table_chroma_dc_422[][4] = {
    /* TC=0 */ {{0x0001, 1}, {0,0}, {0,0}, {0,0}},
    /* TC=1 */ {{0x000F, 7}, {0x0001, 2}, {0,0}, {0,0}},
    /* TC=2 */ {{0x000E, 7}, {0x000D, 7}, {0x0001, 3}, {0,0}},
    /* TC=3 */ {{0x0007, 9}, {0x000C, 7}, {0x000B, 7}, {0x0001, 5}},
    /* TC=4 */ {{0x0006, 9}, {0x0005, 9}, {0x000A, 7}, {0x0001, 6}},
    /* TC=5 */ {{0x0007,10}, {0x0006,10}, {0x0004, 9}, {0x0009, 7}},
    /* TC=6 */ {{0x0007,11}, {0x0006,11}, {0x0005,10}, {0x0008, 7}},
    /* TC=7 */ {{0x0007,12}, {0x0006,12}, {0x0005,11}, {0x0004,10}},
    /* TC=8 */ {{0x0007,13}, {0x0005,12}, {0x0004,12}, {0x0004,11}},
};

static coeff_token_t parse_coeff_token(int nC) {
    coeff_token_t result = {0, 0, 0};
    if (nC >= 8) {
        /* Fixed-length 6-bit code */
        uint32_t code = bs_read_bits(6);
        if (code == 3) {
            result.total_coeffs = 0;
            result.trailing_ones = 0;
        } else {
            result.total_coeffs = (code >> 2) + 1;
            result.trailing_ones = code & 3;
        }
        result.bits_consumed = 6;
        return result;
    }

    /* Select table */
    const vlc_entry_t (*table)[4] = NULL;
    int max_tc = 16;
    if (nC == -2) {
        table = ct_table_chroma_dc_422;
        max_tc = 8;
    } else if (nC == -1) {
        table = ct_table_chroma_dc_420;
        max_tc = 4;
    } else if (nC <= 1) {
        table = ct_table_0;
    } else if (nC <= 3) {
        table = ct_table_1;
    } else if (nC <= 7) {
        table = ct_table_2;
    } else {
        /* should not reach here since nC>=8 handled above */
        table = ct_table_2;
    }

    /* Try to match: peek enough bits and compare */
    for (int tc = 0; tc <= max_tc; tc++) {
        int max_t1 = (tc == 0) ? 0 : (tc < 3 ? tc : 3);
        for (int t1 = 0; t1 <= max_t1; t1++) {
            vlc_entry_t e = table[tc][t1];
            if (e.len == 0) continue;
            if (bs_bit_pos + e.len > bs_len * 8) continue;

            uint32_t peek = bs_peek_bits(e.len);
            if (peek == e.code) {
                result.total_coeffs = tc;
                result.trailing_ones = t1;
                result.bits_consumed = e.len;
                bs_read_bits(e.len);
                return result;
            }
        }
    }

    fprintf(stderr, "ERROR: coeff_token not matched at bit %d (nC=%d), next 16 bits: 0x%04x\n",
            bs_bit_pos, nC, bs_peek_bits(16));
    result.bits_consumed = -1;
    return result;
}

/* ================================================================
 * total_zeros tables (Table 9-7 for luma, Table 9-9(b) for 4:2:2 chroma DC)
 * ================================================================ */

/* Luma total_zeros: indexed by [TotalCoeff-1][total_zeros] = {code, len} */
/* Table 9-7 */
static const vlc_entry_t tz_luma_table[15][16] = {
    /* TC=1 */
    { {1,1},{3,3},{2,3},{3,4},{2,4},{3,5},{2,5},{3,6},{2,6},{3,7},{2,7},{3,8},{2,8},{3,9},{2,9},{1,9} },
    /* TC=2 */
    { {7,3},{6,3},{5,3},{4,3},{3,3},{5,4},{4,4},{3,4},{2,4},{3,5},{2,5},{3,6},{2,6},{1,6},{0,6},{0,0} },
    /* TC=3 */
    { {5,4},{7,3},{6,3},{5,3},{4,4},{3,4},{4,3},{3,3},{2,4},{3,5},{2,5},{1,6},{1,5},{0,6},{0,0},{0,0} },
    /* TC=4 */
    { {3,5},{7,3},{5,4},{4,4},{6,3},{5,3},{4,3},{3,4},{3,3},{2,4},{2,5},{1,5},{0,5},{0,0},{0,0},{0,0} },
    /* TC=5 */
    { {5,4},{4,4},{3,4},{7,3},{6,3},{5,3},{4,3},{3,3},{2,4},{1,5},{1,4},{0,5},{0,0},{0,0},{0,0},{0,0} },
    /* TC=6 */
    { {1,6},{1,5},{7,3},{6,3},{5,3},{4,3},{3,3},{2,3},{1,4},{1,3},{0,6},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=7 */
    { {1,6},{1,5},{5,3},{4,3},{3,3},{3,2},{2,3},{1,4},{1,3},{0,6},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=8 */
    { {1,6},{1,4},{1,5},{3,3},{3,2},{2,2},{2,3},{1,3},{0,6},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=9 */
    { {1,6},{0,6},{1,4},{3,2},{2,2},{1,3},{1,2},{1,5},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=10 */
    { {1,5},{0,5},{1,3},{3,2},{2,2},{1,2},{1,4},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=11 */
    { {0,4},{1,4},{1,3},{2,3},{1,1},{3,3},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=12 */
    { {0,4},{1,4},{1,2},{1,1},{1,3},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=13 */
    { {0,3},{1,3},{1,1},{1,2},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=14 */
    { {0,2},{1,2},{1,1},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=15 */
    { {0,1},{1,1},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
};

/* 4:2:2 chroma DC total_zeros: Table 9-9(b) */
/* Indexed by [TotalCoeff-1][total_zeros], maxNumCoeff=8 */
static const vlc_entry_t tz_chroma_dc_422_table[7][8] = {
    /* TC=1 */ { {1,1},{2,3},{3,3},{2,4},{3,4},{1,4},{1,5},{0,5} },
    /* TC=2 */ { {0,3},{1,2},{1,3},{4,3},{5,3},{6,3},{7,3},{0,0} },
    /* TC=3 */ { {0,3},{1,3},{1,2},{2,2},{6,3},{7,3},{0,0},{0,0} },
    /* TC=4 */ { {6,3},{0,2},{1,2},{2,2},{7,3},{0,0},{0,0},{0,0} },
    /* TC=5 */ { {0,2},{1,2},{2,2},{3,2},{0,0},{0,0},{0,0},{0,0} },
    /* TC=6 */ { {0,2},{1,2},{1,1},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* TC=7 */ { {0,1},{1,1},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
};

/* 4:2:0 chroma DC total_zeros: Table 9-9(a) */
static const vlc_entry_t tz_chroma_dc_420_table[3][4] = {
    /* TC=1 */ { {1,1},{1,2},{1,3},{0,3} },
    /* TC=2 */ { {1,1},{1,2},{0,2},{0,0} },
    /* TC=3 */ { {1,1},{0,1},{0,0},{0,0} },
};

/* Parse total_zeros for luma (maxNumCoeff=16) */
static int parse_total_zeros_luma(int total_coeffs) {
    if (total_coeffs >= 16) return 0;
    int max_tz = 16 - total_coeffs;
    const vlc_entry_t *row = tz_luma_table[total_coeffs - 1];

    for (int tz = 0; tz <= max_tz; tz++) {
        vlc_entry_t e = row[tz];
        if (e.len == 0) continue;
        if (bs_bit_pos + e.len > bs_len * 8) continue;
        uint32_t peek = bs_peek_bits(e.len);
        if (peek == e.code) {
            bs_read_bits(e.len);
            return tz;
        }
    }

    fprintf(stderr, "ERROR: total_zeros (luma) not matched at bit %d (TC=%d), next 16 bits: 0x%04x\n",
            bs_bit_pos, total_coeffs, bs_peek_bits(16));
    return -1;
}

/* Parse total_zeros for 4:2:2 chroma DC (maxNumCoeff=8) */
static int parse_total_zeros_chroma_dc_422(int total_coeffs) {
    if (total_coeffs >= 8) return 0;
    int max_tz = 8 - total_coeffs;
    const vlc_entry_t *row = tz_chroma_dc_422_table[total_coeffs - 1];

    for (int tz = 0; tz <= max_tz; tz++) {
        vlc_entry_t e = row[tz];
        if (e.len == 0) continue;
        if (bs_bit_pos + e.len > bs_len * 8) continue;
        uint32_t peek = bs_peek_bits(e.len);
        if (peek == e.code) {
            bs_read_bits(e.len);
            return tz;
        }
    }

    fprintf(stderr, "ERROR: total_zeros (422 chroma DC) not matched at bit %d (TC=%d), next 16 bits: 0x%04x\n",
            bs_bit_pos, total_coeffs, bs_peek_bits(16));
    return -1;
}

/* Parse total_zeros for 4:2:0 chroma DC (maxNumCoeff=4) */
static int parse_total_zeros_chroma_dc_420(int total_coeffs) {
    if (total_coeffs >= 4) return 0;
    int max_tz = 4 - total_coeffs;
    const vlc_entry_t *row = tz_chroma_dc_420_table[total_coeffs - 1];

    for (int tz = 0; tz <= max_tz; tz++) {
        vlc_entry_t e = row[tz];
        if (e.len == 0) continue;
        if (bs_bit_pos + e.len > bs_len * 8) continue;
        uint32_t peek = bs_peek_bits(e.len);
        if (peek == e.code) {
            bs_read_bits(e.len);
            return tz;
        }
    }

    fprintf(stderr, "ERROR: total_zeros (420 chroma DC) not matched at bit %d (TC=%d), next 16 bits: 0x%04x\n",
            bs_bit_pos, total_coeffs, bs_peek_bits(16));
    return -1;
}

/* ================================================================
 * run_before table (Table 9-10)
 * ================================================================ */

static const vlc_entry_t run_before_table[7][15] = {
    /* zerosLeft=1 */ { {1,1},{0,1},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* zerosLeft=2 */ { {1,1},{1,2},{0,2},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* zerosLeft=3 */ { {3,2},{2,2},{1,2},{0,2},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* zerosLeft=4 */ { {3,2},{2,2},{1,2},{1,3},{0,3},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* zerosLeft=5 */ { {3,2},{2,2},{3,3},{2,3},{1,3},{0,3},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* zerosLeft=6 */ { {3,2},{0,3},{1,3},{3,3},{2,3},{5,3},{4,3},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0},{0,0} },
    /* zerosLeft>=7 */ { {7,3},{6,3},{5,3},{4,3},{3,3},{2,3},{1,3},{1,4},{1,5},{1,6},{1,7},{1,8},{1,9},{1,10},{1,11} },
};

static int parse_run_before(int zeros_left) {
    if (zeros_left <= 0) return 0;

    int table_idx = (zeros_left > 7) ? 6 : zeros_left - 1;
    int max_run = (zeros_left > 14) ? 14 : zeros_left;

    const vlc_entry_t *row = run_before_table[table_idx];

    for (int run = 0; run <= max_run; run++) {
        vlc_entry_t e = row[run];
        if (e.len == 0) continue;
        if (bs_bit_pos + e.len > bs_len * 8) continue;
        uint32_t peek = bs_peek_bits(e.len);
        if (peek == e.code) {
            bs_read_bits(e.len);
            return run;
        }
    }

    fprintf(stderr, "ERROR: run_before not matched at bit %d (zl=%d), next 16 bits: 0x%04x\n",
            bs_bit_pos, zeros_left, bs_peek_bits(16));
    return -1;
}

/* ================================================================
 * CAVLC residual block parser
 * ================================================================ */

typedef enum {
    BLOCK_LUMA,         /* 4x4 luma, maxNumCoeff=16 */
    BLOCK_LUMA_AC,      /* luma AC (skip DC), maxNumCoeff=15 */
    BLOCK_CHROMA_DC_420,/* 4:2:0 chroma DC, maxNumCoeff=4 */
    BLOCK_CHROMA_DC_422,/* 4:2:2 chroma DC, maxNumCoeff=8 */
    BLOCK_CHROMA_AC,    /* chroma AC, maxNumCoeff=15 */
} block_type_t;

static int parse_cavlc_block(int nC, block_type_t btype, const char *label, int *out_total_coeffs) {
    int start_bit = bs_bit_pos;
    int max_coeff;
    int nC_for_ct;

    switch (btype) {
        case BLOCK_LUMA:         max_coeff = 16; nC_for_ct = nC; break;
        case BLOCK_LUMA_AC:      max_coeff = 15; nC_for_ct = nC; break;
        case BLOCK_CHROMA_DC_420:max_coeff = 4;  nC_for_ct = -1; break;
        case BLOCK_CHROMA_DC_422:max_coeff = 8;  nC_for_ct = -2; break;
        case BLOCK_CHROMA_AC:    max_coeff = 15; nC_for_ct = nC; break;
        default:                 max_coeff = 16; nC_for_ct = nC; break;
    }

    /* Parse coeff_token */
    coeff_token_t ct = parse_coeff_token(nC_for_ct);
    if (ct.bits_consumed < 0) {
        printf("  %s: FAILED coeff_token parse at bit %d\n", label, start_bit);
        *out_total_coeffs = 0;
        return -1;
    }

    int total_coeffs = ct.total_coeffs;
    int trailing_ones = ct.trailing_ones;

    *out_total_coeffs = total_coeffs;

    printf("  %s: coeff_token(nC=%d) -> TC=%d T1=%d (%d bits) [bit %d..%d]",
           label, nC_for_ct, total_coeffs, trailing_ones, ct.bits_consumed,
           start_bit, bs_bit_pos - 1);

    if (total_coeffs == 0) {
        printf("\n");
        return 0;
    }

    /* Parse trailing_ones signs */
    int signs[3] = {0, 0, 0};
    if (trailing_ones > 0) {
        for (int i = 0; i < trailing_ones; i++) {
            signs[i] = bs_read_bits(1);
        }
        printf(" signs=");
        for (int i = 0; i < trailing_ones; i++)
            printf("%c", signs[i] ? '-' : '+');
    }

    /* Parse levels */
    int levels[16] = {0};
    int level_idx = 0;

    /* Trailing ones are +/- 1 */
    for (int i = trailing_ones - 1; i >= 0; i--) {
        levels[level_idx++] = signs[i] ? -1 : 1;
    }

    /* Parse remaining levels */
    int suffix_length = (total_coeffs > 10 && trailing_ones < 3) ? 1 : 0;

    for (int i = trailing_ones; i < total_coeffs; i++) {
        /* Parse level_prefix */
        int level_prefix = 0;
        while (!bs_eof() && bs_read_bits(1) == 0)
            level_prefix++;

        int level_suffix_size = 0;
        int level_code;

        if (level_prefix == 14 && suffix_length == 0) {
            level_suffix_size = 4;
        } else if (level_prefix >= 15) {
            level_suffix_size = level_prefix - 3;
            if (suffix_length == 0)
                level_suffix_size = level_prefix - 3;
            /* For prefix==15 with suffixLength==0, suffixSize = 12 */
            if (level_prefix == 15 && suffix_length == 0)
                level_suffix_size = 12;
        } else {
            level_suffix_size = suffix_length;
        }

        int level_suffix = 0;
        if (level_suffix_size > 0)
            level_suffix = bs_read_bits(level_suffix_size);

        level_code = (level_prefix << suffix_length) + level_suffix;

        if (level_prefix >= 15 && suffix_length == 0)
            level_code -= 15;
        if (level_prefix >= 16)
            level_code += (1 << (level_prefix - 3)) - 4096;

        /* First non-trailing-ones level: if trailing_ones < 3, |level| >= 2 */
        if (i == trailing_ones && trailing_ones < 3)
            level_code += 2;

        int level;
        if (level_code % 2 == 0)
            level = (level_code + 2) / 2;
        else
            level = -(level_code + 1) / 2;

        levels[level_idx++] = level;

        /* Update suffix_length */
        int abs_level = level < 0 ? -level : level;
        if (suffix_length == 0)
            suffix_length = (abs_level > 3) ? 2 : 1;
        else if (abs_level > (3 << (suffix_length - 1)))
            suffix_length++;
    }

    printf(" levels={");
    for (int i = 0; i < total_coeffs; i++)
        printf("%s%d", i ? "," : "", levels[i]);
    printf("}");

    /* Parse total_zeros */
    int total_zeros = 0;
    if (total_coeffs < max_coeff) {
        if (btype == BLOCK_CHROMA_DC_422) {
            total_zeros = parse_total_zeros_chroma_dc_422(total_coeffs);
        } else if (btype == BLOCK_CHROMA_DC_420) {
            total_zeros = parse_total_zeros_chroma_dc_420(total_coeffs);
        } else {
            total_zeros = parse_total_zeros_luma(total_coeffs);
        }
        if (total_zeros < 0) {
            printf("\n");
            return -1;
        }
    }

    printf(" tz=%d", total_zeros);

    /* Parse run_before */
    int zeros_left = total_zeros;
    int runs[16] = {0};
    for (int i = 0; i < total_coeffs - 1 && zeros_left > 0; i++) {
        runs[i] = parse_run_before(zeros_left);
        if (runs[i] < 0) {
            printf("\n");
            return -1;
        }
        zeros_left -= runs[i];
    }
    if (total_coeffs > 0)
        runs[total_coeffs - 1] = zeros_left;

    printf(" runs={");
    for (int i = 0; i < total_coeffs; i++)
        printf("%s%d", i ? "," : "", runs[i]);
    printf("}");

    int end_bit = bs_bit_pos;
    printf(" (%d bits total)\n", end_bit - start_bit);

    return 0;
}

/* ================================================================
 * Intra_4x4 CBP table (Table 9-4 for Intra, ChromaArrayType 1 or 2)
 * codeNum -> CBP value (same for ChromaArrayType 1 and 2 per spec)
 * ================================================================ */
static const uint8_t cbp_intra_table[48] = {
    47, 31, 15,  0, 23, 27, 29, 30,  7, 11, 13, 14, 39, 43, 45, 46,
    16,  3,  5, 10, 12, 19, 21, 26, 28, 35, 37, 42, 44,  1,  2,  4,
     8, 17, 18, 20, 24,  6,  9, 22, 25, 32, 33, 34, 36, 40, 38, 41
};

/* ================================================================
 * nC prediction for luma and chroma
 * ================================================================ */

/* Store total_coeffs for each 4x4 block of each MB.
 * Luma: blocks 0..15 (in raster-of-4x4 order)
 * Chroma: Cb blocks 0..7, Cr blocks 0..7  (for 4:2:2)
 *
 * We track per-row nC for left-neighbor prediction.
 * For simplicity in first 50 MBs, we store full grid.
 */

#define MAX_MB_COLS 120  /* support up to 1920 wide */
#define MAX_MBS     200  /* parse up to 200 MBs */

/* Store total_coeffs for each 4x4 luma block */
static int tc_luma[MAX_MBS][16];   /* [mb_idx][block_idx] */
/* Store total_coeffs for each 4x4 chroma block */
static int tc_chroma_cb[MAX_MBS][8]; /* up to 8 for 4:2:2 */
static int tc_chroma_cr[MAX_MBS][8];

/* Get nC for luma block using Table 9-11 neighbor prediction */
static int get_nC_luma(int mb_idx, int block_idx, int mb_cols) {
    /* 4x4 block raster scan order within MB:
     *  0  1  4  5
     *  2  3  6  7
     *  8  9 12 13
     * 10 11 14 15
     */
    /* Map block_idx to (bx, by) in 4x4-block units within the MB */
    static const int blk_x[16] = {0,1,0,1,2,3,2,3,0,1,0,1,2,3,2,3};
    static const int blk_y[16] = {0,0,1,1,0,0,1,1,2,2,3,3,2,2,3,3};

    int bx = blk_x[block_idx];
    int by = blk_y[block_idx];

    int mb_col = mb_idx % mb_cols;

    int nA = -1, nB = -1;  /* -1 = not available */

    /* Left neighbor (A): same by, bx-1 */
    if (bx > 0) {
        /* Same MB -- find block at (bx-1, by) */
        for (int i = 0; i < 16; i++) {
            if (blk_x[i] == bx - 1 && blk_y[i] == by) {
                nA = tc_luma[mb_idx][i];
                break;
            }
        }
    } else if (mb_col > 0) {
        /* Left MB, rightmost column (bx=3) */
        int left_mb = mb_idx - 1;
        for (int i = 0; i < 16; i++) {
            if (blk_x[i] == 3 && blk_y[i] == by) {
                nA = tc_luma[left_mb][i];
                break;
            }
        }
    }

    /* Top neighbor (B): same bx, by-1 */
    if (by > 0) {
        /* Same MB */
        for (int i = 0; i < 16; i++) {
            if (blk_x[i] == bx && blk_y[i] == by - 1) {
                nB = tc_luma[mb_idx][i];
                break;
            }
        }
    } else if (mb_idx >= mb_cols) {
        /* Top MB, bottom row (by=3) */
        int top_mb = mb_idx - mb_cols;
        for (int i = 0; i < 16; i++) {
            if (blk_x[i] == bx && blk_y[i] == 3) {
                nB = tc_luma[top_mb][i];
                break;
            }
        }
    }

    if (nA >= 0 && nB >= 0) return (nA + nB + 1) >> 1;
    if (nA >= 0) return nA;
    if (nB >= 0) return nB;
    return 0;
}

/* Get nC for chroma AC block using neighbors.
 * For 4:2:2, Cb has blocks 0..7 (2 wide x 4 tall in 4x4 units),
 * Cr has blocks 0..7 similarly.
 *
 * Chroma 4x4 block layout within MB (4:2:2, each plane):
 *   Block order: 0 1 / 2 3 / 4 5 / 6 7
 *   So (bx, by) mapping:
 *   Block 0: (0,0), Block 1: (1,0)
 *   Block 2: (0,1), Block 3: (1,1)
 *   Block 4: (0,2), Block 5: (1,2)
 *   Block 6: (0,3), Block 7: (1,3)
 */
static int get_nC_chroma(int mb_idx, int block_idx, int mb_cols, int is_cr) {
    int bx = block_idx & 1;
    int by = block_idx >> 1;
    int mb_col = mb_idx % mb_cols;

    int (*tc_arr)[8] = is_cr ? tc_chroma_cr : tc_chroma_cb;

    int nA = -1, nB = -1;

    /* Left neighbor */
    if (bx > 0) {
        nA = tc_arr[mb_idx][block_idx - 1];
    } else if (mb_col > 0) {
        nA = tc_arr[mb_idx - 1][block_idx + 1]; /* rightmost col of left MB */
    }

    /* Top neighbor */
    if (by > 0) {
        nB = tc_arr[mb_idx][block_idx - 2];
    } else if (mb_idx >= mb_cols) {
        /* Top MB, bottom row */
        int chroma_height_blocks = 4; /* 4:2:2 */
        int top_block = (chroma_height_blocks - 1) * 2 + bx;
        nB = tc_arr[mb_idx - mb_cols][top_block];
    }

    if (nA >= 0 && nB >= 0) return (nA + nB + 1) >> 1;
    if (nA >= 0) return nA;
    if (nB >= 0) return nB;
    return 0;
}

/* ================================================================
 * SPS parsing (minimal, to extract what we need)
 * ================================================================ */

typedef struct {
    int profile_idc;
    int level_idc;
    int chroma_format_idc;
    int bit_depth_luma;
    int bit_depth_chroma;
    int log2_max_frame_num;
    int poc_type;
    int log2_max_poc_lsb;
    int max_num_ref_frames;
    int pic_width_in_mbs;
    int pic_height_in_map_units;
    int frame_mbs_only;
} sps_t;

static sps_t parse_sps(nal_unit_t *nal) {
    sps_t sps = {0};
    bs_buf = nal->rbsp;
    bs_len = nal->rbsp_len;
    bs_bit_pos = 0;

    sps.profile_idc = bs_read_bits(8);
    bs_read_bits(8); /* constraint flags */
    sps.level_idc = bs_read_bits(8);
    uint32_t sps_id = bs_read_ue();
    printf("SPS: profile_idc=%d, level_idc=%d, sps_id=%u\n",
           sps.profile_idc, sps.level_idc, sps_id);

    sps.chroma_format_idc = 1; /* default */
    sps.bit_depth_luma = 8;
    sps.bit_depth_chroma = 8;

    /* High profiles have extra fields */
    if (sps.profile_idc == 100 || sps.profile_idc == 110 ||
        sps.profile_idc == 122 || sps.profile_idc == 244 ||
        sps.profile_idc == 44  || sps.profile_idc == 83  ||
        sps.profile_idc == 86  || sps.profile_idc == 118 ||
        sps.profile_idc == 128 || sps.profile_idc == 138) {
        sps.chroma_format_idc = bs_read_ue();
        printf("  chroma_format_idc=%d\n", sps.chroma_format_idc);
        if (sps.chroma_format_idc == 3) {
            bs_read_bits(1); /* separate_colour_plane_flag */
        }
        sps.bit_depth_luma = bs_read_ue() + 8;
        sps.bit_depth_chroma = bs_read_ue() + 8;
        printf("  bit_depth_luma=%d, bit_depth_chroma=%d\n",
               sps.bit_depth_luma, sps.bit_depth_chroma);
        bs_read_bits(1); /* qpprime_y_zero_transform_bypass */
        int seq_scaling_present = bs_read_bits(1);
        if (seq_scaling_present) {
            int nscl = (sps.chroma_format_idc != 3) ? 8 : 12;
            for (int i = 0; i < nscl; i++) {
                int present = bs_read_bits(1);
                if (present) {
                    /* Skip scaling list */
                    int size = (i < 6) ? 16 : 64;
                    int last_scale = 8, next_scale = 8;
                    for (int j = 0; j < size; j++) {
                        if (next_scale != 0) {
                            int delta = bs_read_se();
                            next_scale = (last_scale + delta + 256) % 256;
                        }
                        last_scale = (next_scale == 0) ? last_scale : next_scale;
                    }
                }
            }
        }
    }

    sps.log2_max_frame_num = bs_read_ue() + 4;
    sps.poc_type = bs_read_ue();
    printf("  log2_max_frame_num=%d, poc_type=%d\n",
           sps.log2_max_frame_num, sps.poc_type);

    if (sps.poc_type == 0) {
        sps.log2_max_poc_lsb = bs_read_ue() + 4;
        printf("  log2_max_poc_lsb=%d\n", sps.log2_max_poc_lsb);
    } else if (sps.poc_type == 1) {
        bs_read_bits(1); /* delta_pic_order_always_zero */
        bs_read_se();    /* offset_for_non_ref_pic */
        bs_read_se();    /* offset_for_top_to_bottom */
        int num_ref = bs_read_ue();
        for (int i = 0; i < num_ref; i++)
            bs_read_se();
    }
    /* poc_type == 2: nothing extra */

    sps.max_num_ref_frames = bs_read_ue();
    bs_read_bits(1); /* gaps_in_frame_num_value_allowed */
    sps.pic_width_in_mbs = bs_read_ue() + 1;
    sps.pic_height_in_map_units = bs_read_ue() + 1;
    sps.frame_mbs_only = bs_read_bits(1);
    printf("  max_ref=%d, width=%d MBs, height=%d MBs, frame_mbs_only=%d\n",
           sps.max_num_ref_frames, sps.pic_width_in_mbs,
           sps.pic_height_in_map_units, sps.frame_mbs_only);

    if (!sps.frame_mbs_only)
        bs_read_bits(1); /* mb_adaptive_frame_field */
    bs_read_bits(1); /* direct_8x8_inference */
    int frame_cropping = bs_read_bits(1);
    if (frame_cropping) {
        bs_read_ue(); bs_read_ue(); bs_read_ue(); bs_read_ue();
    }
    int vui_present = bs_read_bits(1);
    printf("  frame_cropping=%d, vui_present=%d\n", frame_cropping, vui_present);

    return sps;
}

/* ================================================================
 * PPS parsing (minimal)
 * ================================================================ */

typedef struct {
    int pps_id;
    int sps_id;
    int entropy_coding_mode;
    int pic_order_present;
    int num_ref_idx_l0_default;
    int weighted_pred;
    int pic_init_qp;
    int chroma_qp_offset;
    int deblocking_filter_control;
    int constrained_intra;
    int transform_8x8_mode;
    int second_chroma_qp_offset;
} pps_t;

static pps_t parse_pps(nal_unit_t *nal, int profile_idc) {
    pps_t pps = {0};
    bs_buf = nal->rbsp;
    bs_len = nal->rbsp_len;
    bs_bit_pos = 0;

    pps.pps_id = bs_read_ue();
    pps.sps_id = bs_read_ue();
    pps.entropy_coding_mode = bs_read_bits(1);
    pps.pic_order_present = bs_read_bits(1);
    int num_slice_groups = bs_read_ue() + 1;
    pps.num_ref_idx_l0_default = bs_read_ue() + 1;
    int num_ref_idx_l1 = bs_read_ue() + 1;
    pps.weighted_pred = bs_read_bits(1);
    int weighted_bipred = bs_read_bits(2);
    pps.pic_init_qp = bs_read_se() + 26;
    int pic_init_qs = bs_read_se() + 26;
    pps.chroma_qp_offset = bs_read_se();
    pps.deblocking_filter_control = bs_read_bits(1);
    pps.constrained_intra = bs_read_bits(1);
    int redundant_pic_cnt_present = bs_read_bits(1);

    printf("PPS: pps_id=%d, sps_id=%d, entropy_mode=%d, pic_order_present=%d\n",
           pps.pps_id, pps.sps_id, pps.entropy_coding_mode, pps.pic_order_present);
    printf("  num_slice_groups=%d, num_ref_l0=%d, num_ref_l1=%d\n",
           num_slice_groups, pps.num_ref_idx_l0_default, num_ref_idx_l1);
    printf("  weighted_pred=%d, weighted_bipred=%d\n", pps.weighted_pred, weighted_bipred);
    printf("  pic_init_qp=%d, pic_init_qs=%d, chroma_qp_offset=%d\n",
           pps.pic_init_qp, pic_init_qs, pps.chroma_qp_offset);
    printf("  deblocking=%d, constrained_intra=%d, redundant_pic_cnt=%d\n",
           pps.deblocking_filter_control, pps.constrained_intra, redundant_pic_cnt_present);

    /* High profile extras */
    if (profile_idc == 100 || profile_idc == 110 ||
        profile_idc == 122 || profile_idc == 244 ||
        profile_idc == 44  || profile_idc == 83  ||
        profile_idc == 86  || profile_idc == 118 ||
        profile_idc == 128 || profile_idc == 138) {

        /* Check if there are more bits (after redundant_pic_cnt) */
        if (bs_bit_pos < bs_len * 8 - 1) {
            pps.transform_8x8_mode = bs_read_bits(1);
            int pic_scaling_present = bs_read_bits(1);
            if (pic_scaling_present) {
                /* skip scaling lists */
                int nscl = 6 + 2 * pps.transform_8x8_mode;
                for (int i = 0; i < nscl; i++) {
                    if (bs_read_bits(1)) {
                        int size = (i < 6) ? 16 : 64;
                        int last_scale = 8, next_scale = 8;
                        for (int j = 0; j < size; j++) {
                            if (next_scale != 0) {
                                int delta = bs_read_se();
                                next_scale = (last_scale + delta + 256) % 256;
                            }
                            last_scale = (next_scale == 0) ? last_scale : next_scale;
                        }
                    }
                }
            }
            pps.second_chroma_qp_offset = bs_read_se();
            printf("  transform_8x8=%d, second_chroma_qp_offset=%d\n",
                   pps.transform_8x8_mode, pps.second_chroma_qp_offset);
        }
    }

    return pps;
}

/* ================================================================
 * Main: parse file, find IDR, parse slice header + MBs
 * ================================================================ */

int main(int argc, char **argv) {
    const char *filename = (argc > 1) ? argv[1] : "bright_422.h264";
    FILE *fp = fopen(filename, "rb");
    if (!fp) {
        fprintf(stderr, "ERROR: Cannot open %s\n", filename);
        return 1;
    }

    fseek(fp, 0, SEEK_END);
    file_len = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    file_buf = malloc(file_len);
    fread(file_buf, 1, file_len, fp);
    fclose(fp);

    printf("Loaded %s: %d bytes\n\n", filename, file_len);

    /* Scan for NAL units */
    sps_t sps = {0};
    pps_t pps = {0};
    int sps_found = 0, pps_found = 0;
    int profile_idc = 0;

    int offset = 0;
    while (1) {
        int nal_start = find_start_code(offset);
        if (nal_start < 0) break;

        nal_unit_t nal = parse_nal_at(nal_start);
        printf("NAL at offset %d: type=%d, ref_idc=%d, rbsp_len=%d\n",
               nal.file_offset, nal.nal_type, nal.nal_ref_idc, nal.rbsp_len);

        if (nal.nal_type == 7) {
            /* SPS */
            sps = parse_sps(&nal);
            sps_found = 1;
            profile_idc = sps.profile_idc;
            printf("\n");
        } else if (nal.nal_type == 8) {
            /* PPS */
            pps = parse_pps(&nal, profile_idc);
            pps_found = 1;
            printf("\n");
        } else if (nal.nal_type == 5 || nal.nal_type == 1) {
            /* IDR or non-IDR slice */
            if (!sps_found || !pps_found) {
                printf("  (Skipping slice -- SPS/PPS not yet parsed)\n\n");
                free(nal.rbsp);
                offset = find_next_start_code(nal_start);
                continue;
            }

            printf("=== Parsing %s slice ===\n",
                   nal.nal_type == 5 ? "IDR" : "non-IDR");

            bs_buf = nal.rbsp;
            bs_len = nal.rbsp_len;
            bs_bit_pos = 0;

            /* Slice header */
            int first_mb = bs_read_ue();
            int slice_type_ue = bs_read_ue();
            int slice_type = slice_type_ue % 5;
            int pps_id = bs_read_ue();
            int frame_num = bs_read_bits(sps.log2_max_frame_num);

            printf("Slice header: first_mb=%d, slice_type=%d(%s), pps_id=%d, frame_num=%d\n",
                   first_mb, slice_type_ue,
                   slice_type == 0 ? "P" : slice_type == 1 ? "B" : slice_type == 2 ? "I" : "?",
                   pps_id, frame_num);

            if (!sps.frame_mbs_only) {
                int field_pic_flag = bs_read_bits(1);
                printf("  field_pic_flag=%d\n", field_pic_flag);
                if (field_pic_flag)
                    bs_read_bits(1); /* bottom_field_flag */
            }

            if (nal.nal_type == 5) {
                int idr_pic_id = bs_read_ue();
                printf("  idr_pic_id=%d\n", idr_pic_id);
            }

            int pic_order_cnt_lsb = 0;
            if (sps.poc_type == 0) {
                pic_order_cnt_lsb = bs_read_bits(sps.log2_max_poc_lsb);
                printf("  pic_order_cnt_lsb=%d\n", pic_order_cnt_lsb);
                if (pps.pic_order_present /* && !field_pic */) {
                    int delta_poc_bottom = bs_read_se();
                    printf("  delta_pic_order_cnt_bottom=%d\n", delta_poc_bottom);
                }
            }

            /* dec_ref_pic_marking for IDR */
            if (nal.nal_type == 5) {
                int no_output = bs_read_bits(1);
                int long_term = bs_read_bits(1);
                printf("  no_output_of_prior_pics=%d, long_term_ref=%d\n",
                       no_output, long_term);
                if (long_term) {
                    /* Parse adaptive_ref_pic_marking */
                    /* For long_term_reference_flag=1, nothing more needed for IDR */
                }
            }

            /* P-slice reference list reordering */
            if (slice_type == 0) {
                int ref_pic_list_reordering = bs_read_bits(1);
                printf("  ref_pic_list_reordering_l0=%d\n", ref_pic_list_reordering);
                if (ref_pic_list_reordering) {
                    int reorder_op;
                    do {
                        reorder_op = bs_read_ue();
                        if (reorder_op != 3)
                            bs_read_ue(); /* abs_diff */
                    } while (reorder_op != 3);
                }
            }

            int qp_delta = bs_read_se();
            printf("  slice_qp_delta=%d (init_qp=%d -> qp=%d)\n",
                   qp_delta, pps.pic_init_qp, pps.pic_init_qp + qp_delta);

            if (pps.deblocking_filter_control) {
                int disable = bs_read_ue();
                printf("  disable_deblocking_filter_idc=%d\n", disable);
                if (disable != 1) {
                    int alpha = bs_read_se();
                    int beta = bs_read_se();
                    printf("  slice_alpha_c0_offset=%d, slice_beta_offset=%d\n",
                           alpha * 2, beta * 2);
                }
            }

            printf("Slice header consumed %d bits (%d bytes + %d bits)\n\n",
                   bs_bit_pos, bs_bit_pos / 8, bs_bit_pos % 8);

            /* Initialize total_coeffs storage */
            memset(tc_luma, 0, sizeof(tc_luma));
            memset(tc_chroma_cb, 0, sizeof(tc_chroma_cb));
            memset(tc_chroma_cr, 0, sizeof(tc_chroma_cr));

            int mb_cols = sps.pic_width_in_mbs;
            int is_422 = (sps.chroma_format_idc == 2);
            int current_qp = pps.pic_init_qp + qp_delta;

            /* Parse MBs */
            int max_mbs = 50;
            int parse_error = 0;

            for (int mb_idx = 0; mb_idx < max_mbs && !parse_error && !bs_eof(); mb_idx++) {
                int mb_start_bit = bs_bit_pos;
                int mb_x = mb_idx % mb_cols;
                int mb_y = mb_idx / mb_cols;

                printf("--- MB %d (%d,%d) at bit %d ---\n", mb_idx, mb_x, mb_y, mb_start_bit);

                /* P-slice: check for mb_skip_run */
                if (slice_type == 0) {
                    int mb_skip_run = bs_read_ue();
                    printf("  mb_skip_run=%d\n", mb_skip_run);
                    if (mb_skip_run > 0) {
                        /* Skip MBs */
                        printf("  (skipping %d MBs)\n", mb_skip_run);
                        for (int s = 0; s < mb_skip_run && mb_idx + s < max_mbs; s++) {
                            int skip_mb = mb_idx + s;
                            memset(tc_luma[skip_mb], 0, sizeof(tc_luma[skip_mb]));
                            memset(tc_chroma_cb[skip_mb], 0, sizeof(tc_chroma_cb[skip_mb]));
                            memset(tc_chroma_cr[skip_mb], 0, sizeof(tc_chroma_cr[skip_mb]));
                        }
                        mb_idx += mb_skip_run - 1;
                        printf("  MB %d..%d consumed %d bits total\n",
                               mb_idx - mb_skip_run + 1, mb_idx, bs_bit_pos - mb_start_bit);
                        continue;
                    }
                }

                /* mb_type */
                int mb_type_ue = bs_read_ue();
                printf("  mb_type(UE)=%d", mb_type_ue);

                /* For I-slices, mb_type directly indexes I-MB types.
                 * For P-slices, mb_type 0..4 are P-types, 5+ are I-types (offset by 5). */
                int effective_mb_type = mb_type_ue;
                int is_intra = 0;
                int is_I_4x4 = 0;
                int is_I_16x16 = 0;
                int i16_mode = 0, i16_cbpc = 0, i16_cbpl = 0;

                if (slice_type == 2 || slice_type == 7) {
                    /* I-slice */
                    is_intra = 1;
                    if (mb_type_ue == 0) {
                        printf(" (I_4x4)\n");
                        is_I_4x4 = 1;
                    } else if (mb_type_ue >= 1 && mb_type_ue <= 24) {
                        is_I_16x16 = 1;
                        int mt = mb_type_ue - 1;
                        i16_mode = mt % 4;
                        i16_cbpc = (mt / 4) % 3;  /* 0, 1, 2 */
                        i16_cbpl = (mt >= 12) ? 15 : 0;
                        printf(" (I_16x16_%d_%d_%d)\n", i16_mode, i16_cbpc, i16_cbpl);
                    } else if (mb_type_ue == 25) {
                        printf(" (I_PCM)\n");
                        /* Skip PCM data */
                        /* Align to byte boundary */
                        if (bs_bit_pos % 8 != 0)
                            bs_bit_pos = (bs_bit_pos + 7) & ~7;
                        /* Skip 256 luma + chroma samples */
                        int chroma_samples = is_422 ? 256 : 128;
                        int pcm_bits = (256 + chroma_samples) * sps.bit_depth_luma;
                        bs_bit_pos += pcm_bits;
                        printf("  Skipped PCM: %d bits\n", pcm_bits);
                        continue;
                    } else {
                        printf(" (UNKNOWN mb_type=%d)\n", mb_type_ue);
                        parse_error = 1;
                        break;
                    }
                } else {
                    /* P-slice */
                    if (mb_type_ue < 5) {
                        printf(" (P-type %d)\n", mb_type_ue);
                        is_intra = 0;
                        /* For now, handle P_L0_16x16 (type 0) */
                        /* TODO: add full P-MB parsing if needed */
                    } else {
                        effective_mb_type = mb_type_ue - 5;
                        is_intra = 1;
                        if (effective_mb_type == 0) {
                            printf(" (I_4x4 in P)\n");
                            is_I_4x4 = 1;
                        } else if (effective_mb_type >= 1 && effective_mb_type <= 24) {
                            is_I_16x16 = 1;
                            int mt = effective_mb_type - 1;
                            i16_mode = mt % 4;
                            i16_cbpc = (mt / 4) % 3;
                            i16_cbpl = (mt >= 12) ? 15 : 0;
                            printf(" (I_16x16_%d_%d_%d in P)\n", i16_mode, i16_cbpc, i16_cbpl);
                        } else {
                            printf(" (UNKNOWN I-in-P type=%d)\n", effective_mb_type);
                            parse_error = 1;
                            break;
                        }
                    }
                }

                /* === Handle inter MB (P) types === */
                if (!is_intra) {
                    /* P_L0_16x16 = 0, P_L0_L0_16x8 = 1, P_L0_L0_8x16 = 2,
                     * P_8x8 = 3, P_8x8ref0 = 4 */
                    if (mb_type_ue == 0) {
                        /* P_L0_16x16: one MVD */
                        int mvd_x = bs_read_se();
                        int mvd_y = bs_read_se();
                        printf("  mvd: (%d, %d)\n", mvd_x, mvd_y);
                    } else if (mb_type_ue == 1) {
                        /* P_L0_L0_16x8: two MVDs */
                        int mvd_x0 = bs_read_se(), mvd_y0 = bs_read_se();
                        int mvd_x1 = bs_read_se(), mvd_y1 = bs_read_se();
                        printf("  mvd0: (%d,%d), mvd1: (%d,%d)\n", mvd_x0, mvd_y0, mvd_x1, mvd_y1);
                    } else if (mb_type_ue == 2) {
                        /* P_L0_L0_8x16: two MVDs */
                        int mvd_x0 = bs_read_se(), mvd_y0 = bs_read_se();
                        int mvd_x1 = bs_read_se(), mvd_y1 = bs_read_se();
                        printf("  mvd0: (%d,%d), mvd1: (%d,%d)\n", mvd_x0, mvd_y0, mvd_x1, mvd_y1);
                    } else if (mb_type_ue == 3 || mb_type_ue == 4) {
                        /* P_8x8: sub_mb_type for each 8x8 block, then MVDs */
                        printf("  P_8x8 parsing not fully implemented\n");
                        parse_error = 1;
                        break;
                    }

                    /* coded_block_pattern for inter */
                    static const uint8_t cbp_inter_table[48] = {
                        0, 16,  1,  2,  4,  8, 32,  3,  5, 10, 12, 15, 47,  7, 11, 13,
                        14,  6,  9, 31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
                        17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41
                    };

                    int cbp_code = bs_read_ue();
                    int cbp;
                    if (sps.chroma_format_idc == 0) {
                        cbp = (cbp_code < 16) ? cbp_code : 0; /* simplified */
                    } else {
                        cbp = (cbp_code < 48) ? cbp_inter_table[cbp_code] : 0;
                    }
                    int cbp_luma = cbp & 15;
                    int cbp_chroma = cbp >> 4;
                    printf("  CBP: codeNum=%d -> value=%d (luma=%d, chroma=%d)\n",
                           cbp_code, cbp, cbp_luma, cbp_chroma);

                    if (cbp != 0) {
                        int mb_qp_delta = bs_read_se();
                        current_qp += mb_qp_delta;
                        printf("  mb_qp_delta=%d (qp=%d)\n", mb_qp_delta, current_qp);
                    }

                    /* Parse residual for inter */
                    /* Luma: 16 blocks, but only if the 8x8 group's CBP bit is set */
                    printf("  Residual (inter):\n");
                    for (int blk = 0; blk < 16; blk++) {
                        /* H.264 4x4 block indices within the MB follow Table 6-13:
                         * 8x8 block 0: 4x4 blocks 0,1,2,3
                         * 8x8 block 1: 4x4 blocks 4,5,6,7
                         * 8x8 block 2: 4x4 blocks 8,9,10,11
                         * 8x8 block 3: 4x4 blocks 12,13,14,15
                         */
                        int luma_8x8 = blk / 4;
                        if (!((cbp_luma >> luma_8x8) & 1)) {
                            tc_luma[mb_idx][blk] = 0;
                            continue;
                        }
                        int nC = get_nC_luma(mb_idx, blk, mb_cols);
                        char label[32];
                        snprintf(label, sizeof(label), "luma[%d]", blk);
                        int tc;
                        if (parse_cavlc_block(nC, BLOCK_LUMA, label, &tc) < 0) {
                            parse_error = 1;
                            break;
                        }
                        tc_luma[mb_idx][blk] = tc;
                    }
                    if (parse_error) break;

                    /* Chroma */
                    if (sps.chroma_format_idc > 0 && cbp_chroma > 0) {
                        /* Chroma DC (4:2:2 = 8 coeffs, 4:2:0 = 4 coeffs per plane) */
                        block_type_t dc_type = is_422 ? BLOCK_CHROMA_DC_422 : BLOCK_CHROMA_DC_420;
                        int tc;
                        printf("  Chroma DC:\n");
                        if (parse_cavlc_block(-1, dc_type, "chroma_dc_Cb", &tc) < 0) {
                            parse_error = 1; break;
                        }
                        (void)tc;
                        if (parse_cavlc_block(-1, dc_type, "chroma_dc_Cr", &tc) < 0) {
                            parse_error = 1; break;
                        }
                        (void)tc;

                        /* Chroma AC (if cbp_chroma == 2) */
                        if (cbp_chroma == 2) {
                            int num_ac_blocks = is_422 ? 8 : 4;
                            printf("  Chroma AC (Cb):\n");
                            for (int blk = 0; blk < num_ac_blocks && !parse_error; blk++) {
                                int nC = get_nC_chroma(mb_idx, blk, mb_cols, 0);
                                char label[32];
                                snprintf(label, sizeof(label), "chroma_ac_Cb[%d]", blk);
                                int tc2;
                                if (parse_cavlc_block(nC, BLOCK_CHROMA_AC, label, &tc2) < 0) {
                                    parse_error = 1; break;
                                }
                                tc_chroma_cb[mb_idx][blk] = tc2;
                            }
                            printf("  Chroma AC (Cr):\n");
                            for (int blk = 0; blk < num_ac_blocks && !parse_error; blk++) {
                                int nC = get_nC_chroma(mb_idx, blk, mb_cols, 1);
                                char label[32];
                                snprintf(label, sizeof(label), "chroma_ac_Cr[%d]", blk);
                                int tc2;
                                if (parse_cavlc_block(nC, BLOCK_CHROMA_AC, label, &tc2) < 0) {
                                    parse_error = 1; break;
                                }
                                tc_chroma_cr[mb_idx][blk] = tc2;
                            }
                        }
                    }
                    if (parse_error) break;

                    printf("  MB %d total: %d bits consumed (bit %d..%d)\n\n",
                           mb_idx, bs_bit_pos - mb_start_bit, mb_start_bit, bs_bit_pos - 1);
                    continue;
                }

                /* === Intra MB handling === */

                if (is_I_4x4) {
                    /* Parse 16 intra 4x4 pred modes */
                    printf("  Intra 4x4 pred modes:\n");
                    for (int blk = 0; blk < 16; blk++) {
                        int prev_flag = bs_read_bits(1);
                        if (prev_flag) {
                            printf("    block %2d: prev_flag=1 (use predicted)\n", blk);
                        } else {
                            int rem_mode = bs_read_bits(3);
                            printf("    block %2d: prev_flag=0, rem_mode=%d\n", blk, rem_mode);
                        }
                    }

                    /* intra_chroma_pred_mode */
                    int chroma_pred = bs_read_ue();
                    printf("  intra_chroma_pred_mode=%d\n", chroma_pred);

                    /* coded_block_pattern */
                    int cbp_code = bs_read_ue();
                    int cbp;
                    if (sps.chroma_format_idc == 0) {
                        cbp = (cbp_code < 16) ? cbp_code : 0;
                    } else {
                        cbp = (cbp_code < 48) ? cbp_intra_table[cbp_code] : 0;
                    }
                    int cbp_luma = cbp & 15;
                    int cbp_chroma = cbp >> 4;
                    printf("  CBP: codeNum=%d -> value=%d (luma=%d, chroma=%d)\n",
                           cbp_code, cbp, cbp_luma, cbp_chroma);

                    if (cbp != 0) {
                        int mb_qp_delta = bs_read_se();
                        current_qp += mb_qp_delta;
                        printf("  mb_qp_delta=%d (qp=%d)\n", mb_qp_delta, current_qp);
                    }

                    /* Parse residual */
                    if (cbp != 0) {
                        printf("  Residual:\n");

                        /* Luma 4x4 blocks */
                        for (int blk = 0; blk < 16 && !parse_error; blk++) {
                            int luma_8x8 = blk / 4;
                            if (!((cbp_luma >> luma_8x8) & 1)) {
                                tc_luma[mb_idx][blk] = 0;
                                continue;
                            }
                            int nC = get_nC_luma(mb_idx, blk, mb_cols);
                            char label[32];
                            snprintf(label, sizeof(label), "luma[%d]", blk);
                            int tc;
                            if (parse_cavlc_block(nC, BLOCK_LUMA, label, &tc) < 0) {
                                parse_error = 1;
                                break;
                            }
                            tc_luma[mb_idx][blk] = tc;
                        }
                        if (parse_error) break;

                        /* Chroma */
                        if (sps.chroma_format_idc > 0 && cbp_chroma > 0) {
                            /* Chroma DC */
                            block_type_t dc_type = is_422 ? BLOCK_CHROMA_DC_422 : BLOCK_CHROMA_DC_420;
                            int tc;
                            printf("  Chroma DC:\n");
                            if (parse_cavlc_block(-1, dc_type, "chroma_dc_Cb", &tc) < 0) {
                                parse_error = 1; break;
                            }
                            (void)tc;
                            if (parse_cavlc_block(-1, dc_type, "chroma_dc_Cr", &tc) < 0) {
                                parse_error = 1; break;
                            }
                            (void)tc;

                            /* Chroma AC */
                            if (cbp_chroma == 2) {
                                int num_ac_blocks = is_422 ? 8 : 4;
                                printf("  Chroma AC (Cb):\n");
                                for (int blk = 0; blk < num_ac_blocks && !parse_error; blk++) {
                                    int nC = get_nC_chroma(mb_idx, blk, mb_cols, 0);
                                    char label[32];
                                    snprintf(label, sizeof(label), "chroma_ac_Cb[%d]", blk);
                                    int tc2;
                                    if (parse_cavlc_block(nC, BLOCK_CHROMA_AC, label, &tc2) < 0) {
                                        parse_error = 1; break;
                                    }
                                    tc_chroma_cb[mb_idx][blk] = tc2;
                                }
                                printf("  Chroma AC (Cr):\n");
                                for (int blk = 0; blk < num_ac_blocks && !parse_error; blk++) {
                                    int nC = get_nC_chroma(mb_idx, blk, mb_cols, 1);
                                    char label[32];
                                    snprintf(label, sizeof(label), "chroma_ac_Cr[%d]", blk);
                                    int tc2;
                                    if (parse_cavlc_block(nC, BLOCK_CHROMA_AC, label, &tc2) < 0) {
                                        parse_error = 1; break;
                                    }
                                    tc_chroma_cr[mb_idx][blk] = tc2;
                                }
                            }
                        }
                    } else {
                        /* CBP=0: no residual */
                        memset(tc_luma[mb_idx], 0, sizeof(tc_luma[mb_idx]));
                        memset(tc_chroma_cb[mb_idx], 0, sizeof(tc_chroma_cb[mb_idx]));
                        memset(tc_chroma_cr[mb_idx], 0, sizeof(tc_chroma_cr[mb_idx]));
                    }

                } else if (is_I_16x16) {
                    /* I_16x16: intra_chroma_pred_mode */
                    int chroma_pred = bs_read_ue();
                    printf("  intra_chroma_pred_mode=%d\n", chroma_pred);

                    /* CBP is derived from mb_type for I_16x16 */
                    int cbp_luma = i16_cbpl;
                    int cbp_chroma = i16_cbpc;
                    printf("  CBP (from mb_type): luma=%d, chroma=%d\n", cbp_luma, cbp_chroma);

                    /* mb_qp_delta always present for I_16x16 */
                    int mb_qp_delta = bs_read_se();
                    current_qp += mb_qp_delta;
                    printf("  mb_qp_delta=%d (qp=%d)\n", mb_qp_delta, current_qp);

                    printf("  Residual (I_16x16):\n");

                    /* Luma DC (Intra16x16DCLevel, 16 coeffs) */
                    {
                        int nC = get_nC_luma(mb_idx, 0, mb_cols);
                        int tc;
                        /* For I_16x16, the DC block uses nC=-1? No -- it uses luma nC prediction.
                         * Actually Intra16x16DCLevel is coded as a 4x4 block with maxNumCoeff=16
                         * and uses the luma nC. The nC is computed normally. */
                        if (parse_cavlc_block(nC, BLOCK_LUMA, "luma_dc_16x16", &tc) < 0) {
                            parse_error = 1; break;
                        }
                    }

                    /* Luma AC (15 coeffs each, 16 blocks) */
                    for (int blk = 0; blk < 16 && !parse_error; blk++) {
                        int luma_8x8 = blk / 4;
                        if (!((cbp_luma >> luma_8x8) & 1)) {
                            tc_luma[mb_idx][blk] = 0;
                            continue;
                        }
                        int nC = get_nC_luma(mb_idx, blk, mb_cols);
                        char label[32];
                        snprintf(label, sizeof(label), "luma_ac[%d]", blk);
                        int tc;
                        if (parse_cavlc_block(nC, BLOCK_LUMA_AC, label, &tc) < 0) {
                            parse_error = 1; break;
                        }
                        tc_luma[mb_idx][blk] = tc;
                    }
                    if (parse_error) break;

                    /* Chroma */
                    if (sps.chroma_format_idc > 0 && cbp_chroma > 0) {
                        block_type_t dc_type = is_422 ? BLOCK_CHROMA_DC_422 : BLOCK_CHROMA_DC_420;
                        int tc;
                        printf("  Chroma DC:\n");
                        if (parse_cavlc_block(-1, dc_type, "chroma_dc_Cb", &tc) < 0) {
                            parse_error = 1; break;
                        }
                        (void)tc;
                        if (parse_cavlc_block(-1, dc_type, "chroma_dc_Cr", &tc) < 0) {
                            parse_error = 1; break;
                        }
                        (void)tc;

                        if (cbp_chroma == 2) {
                            int num_ac_blocks = is_422 ? 8 : 4;
                            printf("  Chroma AC (Cb):\n");
                            for (int blk = 0; blk < num_ac_blocks && !parse_error; blk++) {
                                int nC = get_nC_chroma(mb_idx, blk, mb_cols, 0);
                                char label[32];
                                snprintf(label, sizeof(label), "chroma_ac_Cb[%d]", blk);
                                int tc2;
                                if (parse_cavlc_block(nC, BLOCK_CHROMA_AC, label, &tc2) < 0) {
                                    parse_error = 1; break;
                                }
                                tc_chroma_cb[mb_idx][blk] = tc2;
                            }
                            printf("  Chroma AC (Cr):\n");
                            for (int blk = 0; blk < num_ac_blocks && !parse_error; blk++) {
                                int nC = get_nC_chroma(mb_idx, blk, mb_cols, 1);
                                char label[32];
                                snprintf(label, sizeof(label), "chroma_ac_Cr[%d]", blk);
                                int tc2;
                                if (parse_cavlc_block(nC, BLOCK_CHROMA_AC, label, &tc2) < 0) {
                                    parse_error = 1; break;
                                }
                                tc_chroma_cr[mb_idx][blk] = tc2;
                            }
                        }
                    }
                }

                if (parse_error) break;

                printf("  MB %d total: %d bits consumed (bit %d..%d)\n\n",
                       mb_idx, bs_bit_pos - mb_start_bit, mb_start_bit, bs_bit_pos - 1);
            }

            if (parse_error) {
                printf("\n*** Parse error at bit %d (byte %d + %d bits) ***\n",
                       bs_bit_pos, bs_bit_pos / 8, bs_bit_pos % 8);
                printf("*** Next 32 bits: 0x%08x ***\n",
                       (bs_bit_pos + 32 <= bs_len * 8) ? bs_peek_bits(32) : 0);
                printf("*** Byte context around error: ");
                int byte_pos = bs_bit_pos / 8;
                for (int i = (byte_pos > 4 ? byte_pos - 4 : 0);
                     i < byte_pos + 8 && i < bs_len; i++) {
                    printf("%02x ", bs_buf[i]);
                }
                printf("***\n");
            }

            /* Only parse first slice */
            free(nal.rbsp);
            break;
        }

        free(nal.rbsp);
        offset = find_next_start_code(nal_start);
    }

    free(file_buf);
    return 0;
}
