// PL source files for Versal reasoning fabric (self-contained)
//
// All modules are local — no external path dependencies.
// This filelist can be used with Vivado, Verilator, or Icarus Verilog.

// Configuration
pl/src/versal_config.svh

// Top-level and lane architecture
pl/src/versal_top.sv
pl/src/lane_tile.sv
pl/src/embedding_projector.sv
pl/src/instrument_bridge.sv

// Stream routing fabric
pl/src/fabric/versal_stream_fabric.sv
pl/src/fabric/stream_router.sv

// Safety chain
pl/src/safety/safety_supervisor.v
pl/src/safety/safety_kernel.sv
pl/src/safety/cbf_solver.sv

// Compute cores (Phase 1: PL-local, Phase 3: replaced by AIE)
pl/src/compute/rc_core.sv
pl/src/compute/bicky_inference.sv

// Plugin interface
pl/src/plugins/modality_plugin_if.sv

// Common IP
pl/src/common/timestamp_counter.v
pl/src/common/crypto_signer.sv
