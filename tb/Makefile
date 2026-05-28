# ---------------------------------------------------------------------------
# Makefile -- Build Verilator simulation for h264_encoder_top
#
# Usage:
#   make              Build the simulator binary
#   make run          Build and run with defaults (1 frame, no trace)
#   make wave         Build and run with VCD tracing
#   make clean        Remove build artifacts
#
# Override on command line:
#   make run FRAMES=10 TIMEOUT=200000000
#   make run YUV_INPUT=/path/to/file.yuv H264_OUTPUT=/path/to/out.h264
#   make WIDTH=1280 HEIGHT=720 run FRAMES=30
# ---------------------------------------------------------------------------

VERILATOR       ?= verilator
TOP_MODULE      := h264_encoder_top
TB_CPP          := tb_h264_encoder.cpp
RTL_DIR         := ../rtl
OBJ_DIR         := obj_dir
SIM_BIN         := V$(TOP_MODULE)

# Resolution (override on command line for different sizes)
WIDTH           ?= 320
HEIGHT          ?= 176
BIT_DEPTH       ?= 8
CHROMA_FORMAT_IDC ?= 1
WEIGHTED_PRED_ENABLE ?= 0
ENABLE_IDR_IPCM ?= 0
ENABLE_P_IPCM ?= 0
IPCM_SAD_THRESHOLD ?= 18000
INTER_SAD_THRESHOLD ?= 8000
ENABLE_CABAC_PSKIP ?= 0
ENABLE_CABAC_P16X16 ?= 0
DEBUG_CABAC_P16X16 ?= 0
ENABLE_CAVLC_LUMA_8X8 ?= 0
BASE_QP ?= 26
MB_QP_DELTA ?= 0
CHROMA_QP_INDEX_OFFSET ?= 0
SECOND_CHROMA_QP_INDEX_OFFSET ?= 0
LUMA_LOG2_WEIGHT_DENOM ?= 0
LUMA_WEIGHT ?= 1
LUMA_OFFSET ?= 0
CHROMA_LOG2_WEIGHT_DENOM ?= 0
CHROMA_WEIGHT_CB ?= 1
CHROMA_OFFSET_CB ?= 0
CHROMA_WEIGHT_CR ?= 1
CHROMA_OFFSET_CR ?= 0
DEBLOCK_ENABLE ?= 1
DISABLE_DEBLOCKING_FILTER_IDC ?= 0
TRACE           ?= 0
TRACE_FILE      ?= output/trace.vcd
EXTRA_VERILATOR_ARGS ?=

ifneq ($(filter wave,$(MAKECMDGOALS)),)
TRACE := 1
endif

# Collect all Verilog sources from the RTL directory
RTL_SRCS        := $(wildcard $(RTL_DIR)/*.v)

# Trace support is optional because Verilator's traced build is fragile for the
# heaviest 10-bit 4:2:2 configuration.
VERILATOR_TRACE_FLAGS :=
ifeq ($(TRACE),1)
VERILATOR_TRACE_FLAGS += --trace
endif

# Verilator flags
VERILATOR_FLAGS := --cc --exe --build --threads 1 \
    -Wall -Wno-fatal \
    $(VERILATOR_TRACE_FLAGS) \
    --top-module $(TOP_MODULE) \
    -I$(RTL_DIR) \
    $(EXTRA_VERILATOR_ARGS) \
    -GFRAME_WIDTH=$(WIDTH) -GFRAME_HEIGHT=$(HEIGHT) -GBIT_DEPTH=$(BIT_DEPTH) -GCHROMA_FORMAT_IDC=$(CHROMA_FORMAT_IDC) \
    -GWEIGHTED_PRED_ENABLE=$(WEIGHTED_PRED_ENABLE) \
    -GENABLE_IDR_IPCM=$(ENABLE_IDR_IPCM) -GENABLE_P_IPCM=$(ENABLE_P_IPCM) \
    -GIPCM_SAD_THRESHOLD=$(IPCM_SAD_THRESHOLD) -GINTER_SAD_THRESHOLD=$(INTER_SAD_THRESHOLD) \
    -GENABLE_CABAC_PSKIP=$(ENABLE_CABAC_PSKIP) \
    -GENABLE_CABAC_P16X16=$(ENABLE_CABAC_P16X16) \
    -GDEBUG_CABAC_P16X16=$(DEBUG_CABAC_P16X16) \
    -GENABLE_CAVLC_LUMA_8X8=$(ENABLE_CAVLC_LUMA_8X8) \
    -GBASE_QP=$(BASE_QP) -GMB_QP_DELTA=$(MB_QP_DELTA) \
    -GCHROMA_QP_INDEX_OFFSET=$(CHROMA_QP_INDEX_OFFSET) -GSECOND_CHROMA_QP_INDEX_OFFSET=$(SECOND_CHROMA_QP_INDEX_OFFSET) \
    -GLUMA_LOG2_WEIGHT_DENOM=$(LUMA_LOG2_WEIGHT_DENOM) -GLUMA_WEIGHT=$(LUMA_WEIGHT) -GLUMA_OFFSET=$(LUMA_OFFSET) \
    -GCHROMA_LOG2_WEIGHT_DENOM=$(CHROMA_LOG2_WEIGHT_DENOM) -GCHROMA_WEIGHT_CB=$(CHROMA_WEIGHT_CB) -GCHROMA_OFFSET_CB=$(CHROMA_OFFSET_CB) \
    -GCHROMA_WEIGHT_CR=$(CHROMA_WEIGHT_CR) -GCHROMA_OFFSET_CR=$(CHROMA_OFFSET_CR) \
    -GDEBLOCK_ENABLE=$(DEBLOCK_ENABLE) -GDISABLE_DEBLOCKING_FILTER_IDC=$(DISABLE_DEBLOCKING_FILTER_IDC) \
    -CFLAGS "-O2 -std=c++17 -DFRAME_W=$(WIDTH) -DFRAME_H=$(HEIGHT) -DBIT_DEPTH=$(BIT_DEPTH) -DCHROMA_FORMAT_IDC=$(CHROMA_FORMAT_IDC)"

# Runtime defaults (override on command line)
FRAMES          ?= 1
TIMEOUT         ?= 100000000
YUV_INPUT       ?= /workspace/data/raw_frames.yuv
H264_OUTPUT     ?= /workspace/output/encoded.h264
EXTRA_PLUSARGS   ?=

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

.PHONY: all run wave clean help

all: $(SIM_BIN)

$(SIM_BIN): $(TB_CPP) $(RTL_SRCS)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(RTL_SRCS) \
		$(TB_CPP) \
		-o $(SIM_BIN)
	@cp -f $(OBJ_DIR)/$(SIM_BIN) ./$(SIM_BIN) 2>/dev/null || true
	@echo ""
	@echo "Build complete: ./$(SIM_BIN)"

run: $(SIM_BIN)
	@mkdir -p $(dir $(H264_OUTPUT))
	./$(SIM_BIN) \
		+frames=$(FRAMES) \
		+timeout=$(TIMEOUT) \
		+input=$(YUV_INPUT) \
		+output=$(H264_OUTPUT) \
		$(EXTRA_PLUSARGS)

wave: $(SIM_BIN)
	@mkdir -p $(dir $(TRACE_FILE))
	@mkdir -p $(dir $(H264_OUTPUT))
	./$(SIM_BIN) \
		+frames=$(FRAMES) \
		+timeout=$(TIMEOUT) \
		+input=$(YUV_INPUT) \
		+output=$(H264_OUTPUT) \
		+trace \
		+trace_file=$(TRACE_FILE) \
		$(EXTRA_PLUSARGS)

clean:
	rm -rf $(OBJ_DIR) $(SIM_BIN) *.vcd

help:
	@echo "Targets:"
	@echo "  all    (default) Build simulator binary"
	@echo "  run    Build and run (FRAMES=1, no trace)"
	@echo "  wave   Build and run with VCD tracing"
	@echo "  clean  Remove build artifacts"
	@echo ""
	@echo "Variables (override on command line):"
	@echo "  FRAMES       Number of frames to encode  (default: 1)"
	@echo "  TIMEOUT      Max simulation cycles        (default: 100000000)"
	@echo "  YUV_INPUT    Raw YUV420 input file         (default: /workspace/data/raw_frames.yuv)"
	@echo "  H264_OUTPUT  Encoded H.264 output file     (default: /workspace/output/encoded.h264)"
	@echo "  TRACE        Enable Verilator VCD tracing  (default: 0)"
	@echo "  TRACE_FILE   Output VCD path               (default: output/trace.vcd)"
	@echo "  WEIGHTED_PRED_ENABLE  Enable weighted P prediction syntax/path"
	@echo "  ENABLE_IDR_IPCM       Enable I_PCM selection on the IDR path"
	@echo "  ENABLE_P_IPCM         Enable I_PCM selection for non-inter P MBs"
	@echo "  IPCM_SAD_THRESHOLD    Intra16 SAD threshold used to choose IDR I_PCM"
	@echo "  INTER_SAD_THRESHOLD   Inter SAD threshold used to choose P inter vs intra"
	@echo "  ENABLE_CABAC_PSKIP    Enable the minimal CABAC skip-capable P-slice subset"
	@echo "  ENABLE_CABAC_P16X16   Enable the minimal CABAC explicit P_L0_16x16 zero-CBP subset"
	@echo "  DEBUG_CABAC_P16X16    Enable non-synthesis CABAC P16x16 bin/state trace prints"
	@echo "  ENABLE_CAVLC_LUMA_8X8 Enable the CAVLC 8x8 luma residual path"
	@echo "  BASE_QP, MB_QP_DELTA, CHROMA_QP_INDEX_OFFSET, SECOND_CHROMA_QP_INDEX_OFFSET"
	@echo "  LUMA_LOG2_WEIGHT_DENOM, LUMA_WEIGHT, LUMA_OFFSET"
	@echo "  CHROMA_LOG2_WEIGHT_DENOM, CHROMA_WEIGHT_CB, CHROMA_OFFSET_CB"
	@echo "  CHROMA_WEIGHT_CR, CHROMA_OFFSET_CR"
	@echo "  DEBLOCK_ENABLE, DISABLE_DEBLOCKING_FILTER_IDC"
	@echo "  EXTRA_VERILATOR_ARGS  Additional Verilator/parameter args"
	@echo "  EXTRA_PLUSARGS  Additional +args for sim"
	@echo ""
	@echo "Examples:"
	@echo "  make run FRAMES=10"
	@echo "  make wave FRAMES=1 TIMEOUT=5000000"
	@echo "  make run WIDTH=32 HEIGHT=16 BIT_DEPTH=10 CHROMA_FORMAT_IDC=2"
