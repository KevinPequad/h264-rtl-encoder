#include <verilated.h>
#include "Vh264_cabac_residual4x4_scan.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

struct Event {
    int kind;
    int value;
    int idx;
    int level_abs;
    int sign;
};

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vh264_cabac_residual4x4_scan* dut) {
    dut->clk = 0;
    dut->eval();
    main_time++;
    dut->clk = 1;
    dut->eval();
    main_time++;
}

static void clear_coeffs(Vh264_cabac_residual4x4_scan* dut) {
    dut->coeff0 = 0;  dut->coeff1 = 0;  dut->coeff2 = 0;  dut->coeff3 = 0;
    dut->coeff4 = 0;  dut->coeff5 = 0;  dut->coeff6 = 0;  dut->coeff7 = 0;
    dut->coeff8 = 0;  dut->coeff9 = 0;  dut->coeff10 = 0; dut->coeff11 = 0;
    dut->coeff12 = 0; dut->coeff13 = 0; dut->coeff14 = 0; dut->coeff15 = 0;
}

static std::vector<Event> run_case(Vh264_cabac_residual4x4_scan* dut) {
    std::vector<Event> events;
    dut->event_ready = 1;
    dut->start = 1;
    tick(dut);
    dut->start = 0;

    for (int cyc = 0; cyc < 200; ++cyc) {
        if (dut->event_valid) {
            events.push_back(Event{
                static_cast<int>(dut->event_kind),
                static_cast<int>(dut->event_value),
                static_cast<int>(dut->event_coeff_idx),
                static_cast<int>(dut->event_level_abs),
                static_cast<int>(dut->event_level_sign),
            });
        }
        if (dut->done) {
            tick(dut);
            return events;
        }
        tick(dut);
    }
    std::cerr << "Timed out waiting for residual scan done\n";
    std::exit(1);
}

static void expect_eq(const std::vector<Event>& got, const std::vector<Event>& want, const std::string& name) {
    if (got.size() != want.size()) {
        std::cerr << name << ": event count mismatch got=" << got.size() << " want=" << want.size() << "\n";
        std::exit(1);
    }
    for (size_t i = 0; i < want.size(); ++i) {
        if (got[i].kind != want[i].kind || got[i].value != want[i].value || got[i].idx != want[i].idx ||
            got[i].level_abs != want[i].level_abs || got[i].sign != want[i].sign) {
            std::cerr << name << ": event " << i << " mismatch\n"
                      << "  got  kind=" << got[i].kind << " value=" << got[i].value << " idx=" << got[i].idx
                      << " level_abs=" << got[i].level_abs << " sign=" << got[i].sign << "\n"
                      << "  want kind=" << want[i].kind << " value=" << want[i].value << " idx=" << want[i].idx
                      << " level_abs=" << want[i].level_abs << " sign=" << want[i].sign << "\n";
            std::exit(1);
        }
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_cabac_residual4x4_scan* dut = new Vh264_cabac_residual4x4_scan;

    dut->rst_n = 0;
    dut->start = 0;
    dut->event_ready = 1;
    dut->max_coeff_minus1 = 15;
    clear_coeffs(dut);
    for (int i = 0; i < 4; ++i) tick(dut);
    dut->rst_n = 1;
    tick(dut);

    clear_coeffs(dut);
    auto zero = run_case(dut);
    expect_eq(zero, {
        {0, 0, 0, 0, 0}, // CBF=0, no significant/level/sign events
    }, "zero_block");

    clear_coeffs(dut);
    dut->max_coeff_minus1 = 15;
    dut->coeff0 = 1;
    dut->coeff3 = static_cast<uint16_t>(-2);
    auto sparse = run_case(dut);
    expect_eq(sparse, {
        {0, 1, 0, 0, 0}, // CBF=1
        {1, 1, 0, 0, 0}, // significant coeff 0
        {2, 0, 0, 0, 0}, // not last
        {1, 0, 1, 0, 0}, // coeff 1 not significant
        {1, 0, 2, 0, 0}, // coeff 2 not significant
        {1, 1, 3, 0, 0}, // significant coeff 3
        {2, 1, 3, 0, 0}, // last significant coeff
        {3, 1, 3, 2, 1}, // level abs=2, emitted reverse-scan first
        {4, 1, 3, 2, 1}, // sign negative
        {3, 1, 0, 1, 0}, // level abs=1
        {4, 0, 0, 1, 0}, // sign positive
    }, "sparse_block");

    clear_coeffs(dut);
    dut->max_coeff_minus1 = 3;
    dut->coeff2 = 3;
    dut->coeff5 = static_cast<uint16_t>(-4); // outside max_coeff_minus1, must be ignored
    auto chroma_dc_limited = run_case(dut);
    expect_eq(chroma_dc_limited, {
        {0, 1, 0, 0, 0}, // CBF=1
        {1, 0, 0, 0, 0}, // coeff 0 not significant
        {1, 0, 1, 0, 0}, // coeff 1 not significant
        {1, 1, 2, 0, 0}, // coeff 2 significant
        {2, 1, 2, 0, 0}, // coeff 2 last within 4-coeff chroma DC scan
        {3, 1, 2, 3, 0}, // level abs=3
        {4, 0, 2, 3, 0}, // sign positive
    }, "chroma_dc_limited_scan");

    clear_coeffs(dut);
    dut->max_coeff_minus1 = 14;
    dut->coeff0 = static_cast<uint16_t>(-1);
    dut->coeff14 = 2;
    dut->coeff15 = 7; // outside chroma-AC max_coeff_minus1, must be ignored
    auto chroma_ac_limited = run_case(dut);
    expect_eq(chroma_ac_limited, {
        {0, 1, 0, 0, 0},  // CBF=1
        {1, 1, 0, 0, 0},  // coeff 0 significant
        {2, 0, 0, 0, 0},  // coeff 0 not last
        {1, 0, 1, 0, 0},  // coeff 1 not significant
        {1, 0, 2, 0, 0},  // coeff 2 not significant
        {1, 0, 3, 0, 0},  // coeff 3 not significant
        {1, 0, 4, 0, 0},  // coeff 4 not significant
        {1, 0, 5, 0, 0},  // coeff 5 not significant
        {1, 0, 6, 0, 0},  // coeff 6 not significant
        {1, 0, 7, 0, 0},  // coeff 7 not significant
        {1, 0, 8, 0, 0},  // coeff 8 not significant
        {1, 0, 9, 0, 0},  // coeff 9 not significant
        {1, 0, 10, 0, 0}, // coeff 10 not significant
        {1, 0, 11, 0, 0}, // coeff 11 not significant
        {1, 0, 12, 0, 0}, // coeff 12 not significant
        {1, 0, 13, 0, 0}, // coeff 13 not significant
        {1, 1, 14, 0, 0}, // coeff 14 significant
        {2, 1, 14, 0, 0}, // coeff 14 last within 15-coeff chroma AC scan
        {3, 1, 14, 2, 0}, // level abs=2, emitted reverse-scan first
        {4, 0, 14, 2, 0}, // sign positive
        {3, 1, 0, 1, 1},  // level abs=1
        {4, 1, 0, 1, 1},  // sign negative
    }, "chroma_ac_limited_scan");

    std::cout << "[PASS] CABAC residual scan events matched expected luma, limited chroma-DC, and limited chroma-AC blocks\n";
    delete dut;
    return 0;
}
