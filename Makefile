# Makefile — Versal VCK190 Parallel Reasoning Fabric
#
# Targets for simulation, synthesis, and AIE compilation.
# Simulation targets use Icarus Verilog (open-source, no Vivado needed).

IVERILOG  ?= iverilog
VVP       ?= vvp
VERILATOR ?= verilator

PL_SRC    = pl/src
PL_TB     = pl/tb
BUILD     = build

# All PL source files (order matters for include resolution)
PL_SRCS = \
	$(PL_SRC)/versal_config.svh \
	$(PL_SRC)/plugins/modality_plugin_if.sv \
	$(PL_SRC)/common/timestamp_counter.v \
	$(PL_SRC)/common/crypto_signer.sv \
	$(PL_SRC)/safety/safety_supervisor.v \
	$(PL_SRC)/safety/cbf_solver.sv \
	$(PL_SRC)/safety/safety_kernel.sv \
	$(PL_SRC)/fabric/stream_router.sv \
	$(PL_SRC)/compute/rc_core.sv \
	$(PL_SRC)/compute/bicky_inference.sv \
	$(PL_SRC)/embedding_projector.sv \
	$(PL_SRC)/instrument_bridge.sv \
	$(PL_SRC)/lane_tile.sv \
	$(PL_SRC)/fabric/versal_stream_fabric.sv \
	$(PL_SRC)/versal_top.sv

.PHONY: sim-lane sim-all lint clean help

help:
	@echo "Versal Reasoning Fabric — Build Targets"
	@echo ""
	@echo "  make sim-lane    Simulate single lane tile (Icarus Verilog)"
	@echo "  make lint        Lint all PL sources (Verilator)"
	@echo "  make clean       Remove build artifacts"
	@echo ""
	@echo "Vivado targets (requires Vivado 2023.2+):"
	@echo "  make vivado-project   Create Vivado project"
	@echo "  make vivado-synth     Run synthesis"
	@echo ""
	@echo "AIE targets (requires Vitis 2023.2+):"
	@echo "  make aie-compile      Compile AIE kernels"
	@echo ""

# --------------------------------------------------------------------------
# Simulation (Icarus Verilog)
# --------------------------------------------------------------------------

$(BUILD):
	mkdir -p $(BUILD)

sim-lane: $(BUILD)
	$(IVERILOG) -g2012 -Wall \
		-I$(PL_SRC) \
		-o $(BUILD)/tb_lane_tile.vvp \
		$(PL_SRCS) \
		$(PL_TB)/tb_lane_tile.sv
	$(VVP) $(BUILD)/tb_lane_tile.vvp
	@echo "--- Lane tile simulation complete ---"

sim-all: sim-lane
	@echo "--- All simulations passed ---"

# --------------------------------------------------------------------------
# Lint (Verilator)
# --------------------------------------------------------------------------

lint:
	$(VERILATOR) --lint-only -Wall \
		-I$(PL_SRC) \
		--top-module versal_top \
		$(PL_SRCS) \
		|| echo "WARN: Verilator lint found issues (non-blocking)"

# --------------------------------------------------------------------------
# Vivado (requires Vivado 2023.2+)
# --------------------------------------------------------------------------

vivado-project:
	vivado -mode batch -source scripts/create_project.tcl

vivado-synth: vivado-project
	vivado -mode batch -source scripts/run_synth.tcl

# --------------------------------------------------------------------------
# AIE (requires Vitis 2023.2+)
# --------------------------------------------------------------------------

aie-compile:
	$(MAKE) -C aie aie-compile

# --------------------------------------------------------------------------
# Clean
# --------------------------------------------------------------------------

clean:
	rm -rf $(BUILD) vivado_proj/ aie/build/
	rm -f *.jou *.log *.str
