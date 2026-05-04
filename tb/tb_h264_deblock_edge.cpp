#include "Vh264_deblock_check_top.h"
#include "verilated.h"
#include <array>
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

static const int alpha_table[52] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    4,4,5,6,7,8,9,10,12,13,15,17,20,22,25,28,
    32,36,40,45,50,56,63,71,80,90,101,113,127,144,162,182,203,226,255,255
};
static const int beta_table[52] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    2,2,2,3,3,3,3,4,4,4,6,6,7,7,8,8,
    9,9,10,10,11,11,12,12,13,13,14,14,15,15,16,16,17,17,18,18
};
static const int tc0_table[52][4] = {
    {-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},
    {-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},
    {-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,0},{-1,0,0,1},
    {-1,0,0,1},{-1,0,0,1},{-1,0,0,1},{-1,0,1,1},{-1,0,1,1},{-1,1,1,1},
    {-1,1,1,1},{-1,1,1,1},{-1,1,1,1},{-1,1,1,2},{-1,1,1,2},{-1,1,1,2},
    {-1,1,1,2},{-1,1,2,3},{-1,1,2,3},{-1,2,2,3},{-1,2,2,4},{-1,2,3,4},
    {-1,2,3,4},{-1,3,3,5},{-1,3,4,6},{-1,3,4,6},{-1,4,5,7},{-1,4,5,8},
    {-1,4,6,9},{-1,5,7,10},{-1,6,8,11},{-1,6,8,13},{-1,7,10,14},{-1,8,11,16},
    {-1,9,12,18},{-1,10,13,20},{-1,11,15,23},{-1,13,17,25}
};

static int clip3(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static int clip1(int v) { return clip3(v, 0, 255); }
static int abs_i(int v) { return v < 0 ? -v : v; }

struct EdgeOut { int p2, p1, p0, q0, q1, q2; };

static EdgeOut oracle_edge(int bs, bool chroma, int p3, int p2, int p1, int p0, int q0, int q1, int q2, int q3, int alpha, int beta, int tc0) {
    EdgeOut o{p2, p1, p0, q0, q1, q2};
    if (bs == 0) return o;
    if (!(abs_i(p0 - q0) < alpha && abs_i(p1 - p0) < beta && abs_i(q1 - q0) < beta)) return o;
    if (bs >= 4) {
        if (chroma) {
            o.p0 = clip1((2 * p1 + p0 + q1 + 2) >> 2);
            o.q0 = clip1((2 * q1 + q0 + p1 + 2) >> 2);
        } else if (abs_i(p0 - q0) < ((alpha >> 2) + 2)) {
            if (abs_i(p2 - p0) < beta) {
                o.p0 = clip1((p2 + 2*p1 + 2*p0 + 2*q0 + q1 + 4) >> 3);
                o.p1 = clip1((p2 + p1 + p0 + q0 + 2) >> 2);
                o.p2 = clip1((2*p3 + 3*p2 + p1 + p0 + q0 + 4) >> 3);
            } else {
                o.p0 = clip1((2*p1 + p0 + q1 + 2) >> 2);
            }
            if (abs_i(q2 - q0) < beta) {
                o.q0 = clip1((p1 + 2*p0 + 2*q0 + 2*q1 + q2 + 4) >> 3);
                o.q1 = clip1((p0 + q0 + q1 + q2 + 2) >> 2);
                o.q2 = clip1((2*q3 + 3*q2 + q1 + q0 + p0 + 4) >> 3);
            } else {
                o.q0 = clip1((2*q1 + q0 + p1 + 2) >> 2);
            }
        } else {
            o.p0 = clip1((2*p1 + p0 + q1 + 2) >> 2);
            o.q0 = clip1((2*q1 + q0 + p1 + 2) >> 2);
        }
    } else {
        int tc = tc0;
        if (chroma) {
            int delta = clip3((((q0 - p0) * 4) + (p1 - q1) + 4) >> 3, -tc, tc);
            o.p0 = clip1(p0 + delta);
            o.q0 = clip1(q0 - delta);
        } else {
            if (abs_i(p2 - p0) < beta) {
                if (tc0) o.p1 = clip1(p1 + clip3(((p2 + ((p0 + q0 + 1) >> 1)) >> 1) - p1, -tc0, tc0));
                tc++;
            }
            if (abs_i(q2 - q0) < beta) {
                if (tc0) o.q1 = clip1(q1 + clip3(((q2 + ((p0 + q0 + 1) >> 1)) >> 1) - q1, -tc0, tc0));
                tc++;
            }
            int delta = clip3((((q0 - p0) * 4) + (p1 - q1) + 4) >> 3, -tc, tc);
            o.p0 = clip1(p0 + delta);
            o.q0 = clip1(q0 - delta);
        }
    }
    return o;
}

static void drive_edge(Vh264_deblock_check_top& dut, int idx_a, int idx_b, int bs, bool chroma,
                       int p3, int p2, int p1, int p0, int q0, int q1, int q2, int q3) {
    dut.index_a = idx_a;
    dut.index_b = idx_b;
    dut.bs = bs;
    dut.chroma_edge = chroma ? 1 : 0;
    dut.p3 = p3; dut.p2 = p2; dut.p1 = p1; dut.p0 = p0;
    dut.q0 = q0; dut.q1 = q1; dut.q2 = q2; dut.q3 = q3;
    dut.eval();
}

static int failures = 0;
static void expect_eq(const std::string& name, int got, int exp) {
    if (got != exp) {
        std::cerr << "FAIL " << name << ": got=" << got << " expected=" << exp << "\n";
        failures++;
    }
}

static void check_edge_case(Vh264_deblock_check_top& dut, const std::string& name, int idx, int bs, bool chroma,
                            int p3, int p2, int p1, int p0, int q0, int q1, int q2, int q3) {
    drive_edge(dut, idx, idx, bs, chroma, p3, p2, p1, p0, q0, q1, q2, q3);
    int tc = (bs >= 4) ? 0 : tc0_table[idx][bs];
    EdgeOut exp = oracle_edge(bs, chroma, p3, p2, p1, p0, q0, q1, q2, q3, alpha_table[idx], beta_table[idx], tc);
    expect_eq(name + ".alpha", dut.alpha, alpha_table[idx]);
    expect_eq(name + ".beta", dut.beta, beta_table[idx]);
    expect_eq(name + ".tc0", (int)((int8_t)dut.tc0), tc);
    expect_eq(name + ".p2", dut.p2_out, exp.p2);
    expect_eq(name + ".p1", dut.p1_out, exp.p1);
    expect_eq(name + ".p0", dut.p0_out, exp.p0);
    expect_eq(name + ".q0", dut.q0_out, exp.q0);
    expect_eq(name + ".q1", dut.q1_out, exp.q1);
    expect_eq(name + ".q2", dut.q2_out, exp.q2);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_deblock_check_top dut;

    for (int idx : {0, 15, 16, 23, 24, 25, 26, 31, 40, 51}) {
        drive_edge(dut, idx, idx, 2, false, 50, 51, 52, 60, 62, 64, 65, 66);
        expect_eq("table.alpha." + std::to_string(idx), dut.alpha, alpha_table[idx]);
        expect_eq("table.beta." + std::to_string(idx), dut.beta, beta_table[idx]);
        expect_eq("table.tc0_bs2." + std::to_string(idx), (int)((int8_t)dut.tc0), tc0_table[idx][2]);
    }

    check_edge_case(dut, "luma_inter_delta_p0q0", 26, 2, false, 52, 52, 52, 60, 62, 64, 64, 64);
    check_edge_case(dut, "luma_inter_no_filter_alpha", 26, 2, false, 10, 10, 10, 10, 80, 80, 80, 80);
    check_edge_case(dut, "chroma_inter_p0q0_only", 31, 2, true, 54, 54, 54, 60, 63, 65, 65, 65);
    check_edge_case(dut, "luma_intra_strong", 32, 4, false, 45, 48, 50, 52, 55, 57, 59, 61);
    check_edge_case(dut, "chroma_intra", 32, 4, true, 45, 48, 50, 52, 55, 57, 59, 61);

    if (failures) {
        std::cerr << "DEBLOCK_EDGE_CHECK FAIL failures=" << failures << "\n";
        return 1;
    }
    std::cout << "DEBLOCK_EDGE_CHECK PASS vectors=15\n";
    return 0;
}
