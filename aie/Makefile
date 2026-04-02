# Makefile for AIE kernel compilation (Versal VCK190)
#
# Prerequisites:
#   - Vitis 2023.2+ installed and sourced (settings64.sh)
#   - VCK190 platform installed ($PLATFORM_REPO_PATHS set)
#
# Usage:
#   make aie-compile    # Compile AIE graph
#   make aie-sim        # Run AIE simulation
#   make clean          # Remove build artifacts

PLATFORM ?= xilinx_vck190_base_202320_1
AIE_SRC   = src
WORK_DIR  = build/aie_work
TARGET   ?= hw  # hw or x86sim

# AIE compiler flags
AIE_FLAGS  = --target=$(TARGET)
AIE_FLAGS += --platform=$(PLATFORM)
AIE_FLAGS += -include=$(AIE_SRC)/kernels
AIE_FLAGS += -include=$(AIE_SRC)/graphs
AIE_FLAGS += --workdir=$(WORK_DIR)

# Top-level graph
TOP_GRAPH = $(AIE_SRC)/graphs/reasoning_graph.h

.PHONY: aie-compile aie-sim clean

aie-compile:
	@mkdir -p $(WORK_DIR)
	aiecompiler $(AIE_FLAGS) $(TOP_GRAPH)
	@echo "AIE compilation complete. Output in $(WORK_DIR)/"

aie-sim: aie-compile
	aiesimulator --pkg-dir=$(WORK_DIR) --dump-vcd=aie_sim
	@echo "AIE simulation complete."

clean:
	rm -rf $(WORK_DIR) build/
