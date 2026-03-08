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

# Collect all Verilog sources from the RTL directory
RTL_SRCS        := $(wildcard $(RTL_DIR)/*.v)

# Verilator flags
VERILATOR_FLAGS := --cc --exe --build \
    -Wall -Wno-fatal \
    --trace \
    --top-module $(TOP_MODULE) \
    -I$(RTL_DIR) \
    -GFRAME_WIDTH=$(WIDTH) -GFRAME_HEIGHT=$(HEIGHT) -GBIT_DEPTH=$(BIT_DEPTH) -GCHROMA_FORMAT_IDC=$(CHROMA_FORMAT_IDC) \
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
	@mkdir -p $(dir $(H264_OUTPUT))
	./$(SIM_BIN) \
		+frames=$(FRAMES) \
		+timeout=$(TIMEOUT) \
		+input=$(YUV_INPUT) \
		+output=$(H264_OUTPUT) \
		+trace \
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
	@echo "  EXTRA_PLUSARGS  Additional +args for sim"
	@echo ""
	@echo "Examples:"
	@echo "  make run FRAMES=10"
	@echo "  make wave FRAMES=1 TIMEOUT=5000000"
	@echo "  make run EXTRA_PLUSARGS='+trace'"
