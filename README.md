# Versal Reasoning Fabric

> **Status: Research / Pre-silicon** -- This is a reference architecture for
> FPGA-accelerated multi-agent reasoning. The PL (programmable logic) is
> architecturally validated against proven modules from a production Zynq-7000
> deployment. The AIE kernels are untested drafts. We are seeking collaborators
> with VCK190 hardware to validate and extend.

A parallel hardware fabric for AI agent orchestration and lab instrument
integration, targeting the AMD Versal AI Core Series VCK190 evaluation kit.

## What This Is

This project scales a proven sensor-processing FPGA architecture into a
multi-lane reasoning fabric where each lane can independently process AI
agent state, lab instrument data, or sensor streams -- all with hardware
safety gating, priority-based arbitration, and cryptographic provenance.

The core insight: an AI agent reasoning pipeline and a sensor DSP pipeline
have the same structure -- streaming data through parallel processing cores
with safety constraints. This project implements that generalization in RTL.

**Companion project:** [bicky-bee](https://github.com/TidewaterAI/bicky-bee) (open-source release pending) --
the working beehive monitoring pipeline that proves the architecture. Same
RC/Bicky inference engines, same safety modules, same stream router. bicky-bee
runs on a $200 Zybo Z7-20; this project scales it to a $10K Versal with 400
AI Engine tiles.

## Architecture

```
                PS (Cortex-A72 + R5F)
                |  AXI / NoC / DMA
                v
  +----------------------------------------------------+
  |              versal_top.sv (PL, 250 MHz)           |
  |                                                      |
  |  +---------+  +---------+  +---------+  +---------+ |
  |  | Lane 0  |  | Lane 1  |  | Lane 2  |  | Lane 3  | |
  |  | rc_core |  | rc_core |  | rc_core |  | rc_core | |
  |  | bicky   |  | bicky   |  | bicky   |  | bicky   | |
  |  | safety  |  | safety  |  | safety  |  | safety  | |
  |  +----+----+  +----+----+  +----+----+  +----+----+ |
  |       |            |            |            |       |
  |  +----v------------v------------v------------v----+  |
  |  | versal_stream_fabric (9:1 priority router)     |  |
  |  +--+---------------------------------------------+  |
  |     |                                                |
  |  +--v---------+  +----------------+  +-----------+  |
  |  | safety_    |  | timestamp      |  | crypto    |  |
  |  | supervisor |  | counter (PPS)  |  | signer    |  |
  |  +------------+  +----------------+  +-----------+  |
  |                                                      |
  |  +------------------------------------------------+  |
  |  | Instrument Bridges (Scope, VNA, Thermal, ...)  |  |
  |  +------------------------------------------------+  |
  +----------------------------------------------------+
                |  PLIO (Phase 3)
                v
  +----------------------------------------------------+
  |         AI Engine Array (400 tiles, 1 GHz)         |
  |  Per-lane: matvec_q15 + rc_update (SIMD Q1.15)    |
  +----------------------------------------------------+
```

## Quick Start

### Simulate (no hardware needed)

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) (open-source):

```bash
git clone https://github.com/TidewaterAI/versal-reasoning-fabric
cd versal-reasoning-fabric
make sim-lane
```

This compiles and runs the lane tile testbench, which sends a 13-dim Q1.15
feature vector through an RC core lane and verifies output.

### Lint

Requires [Verilator](https://www.veripool.org/verilator/) (open-source):

```bash
make lint
```

### Synthesize (requires Vivado 2023.2+)

```bash
make vivado-project    # Creates Vivado project targeting XCVC1902
# Then open vivado_proj/ in Vivado GUI for block design wiring
```

## What's Inside

### PL Modules (Programmable Logic)

| Module | Origin | Purpose | Status |
|--------|--------|---------|--------|
| `versal_top.sv` | New | Top-level: N lanes + fabric + safety | Designed |
| `lane_tile.sv` | New | Single reasoning lane (RC/Bicky + safety) | Designed |
| `versal_stream_fabric.sv` | New | N:1 priority stream arbitration | Designed |
| `embedding_projector.sv` | New | Matrix-vector dimensionality reduction | Designed |
| `instrument_bridge.sv` | New | Lab instrument -> fabric adapter | Designed |
| `stream_router.sv` | Proven | N:1 AXI-Stream priority arbiter | Production |
| `safety_supervisor.v` | Proven | Watchdog, kill latch, duty accounting | Production |
| `safety_kernel.sv` | Proven | CBF constraint enforcement | Production |
| `cbf_solver.sv` | Proven | Constrained optimization (geofence/velocity) | Production |
| `modality_plugin_if.sv` | Proven | Standard plugin interface | Production |
| `rc_core.sv` | Proven | 256-node reservoir computing (Q1.15) | Production |
| `bicky_inference.sv` | Proven | Feedforward neural classifier (Q1.15) | Production |
| `timestamp_counter.v` | Proven | PTP/PPS-locked 64-bit timing | Production |
| `crypto_signer.sv` | Proven | Frame signing (mock, upgrade to ATECC608) | Production |

"Proven" = synthesized, timing-met, and validated on Zynq-7000 hardware in
the [bicky-bee](https://github.com/TidewaterAI/bicky-bee) deployment.

### AIE Kernels (AI Engine -- Experimental)

| File | Purpose | Status |
|------|---------|--------|
| `matvec_q15.{h,cc}` | Q1.15 SIMD matrix-vector multiply | Draft |
| `rc_update.{h,cc}` | Tanh activation + leaky integration | Draft |
| `rc_graph.h` | Per-lane RC dataflow graph | Draft |
| `reasoning_graph.h` | Multi-lane top-level graph | Draft |

See [aie/README.md](aie/README.md) for details and validation needs.

## Resource Estimates

| Resource | XCVC1902 Available | 4-Lane PL-Only | 16-Lane PL+AIE |
|----------|-------------------|---------------|----------------|
| LUTs | 1,968K | ~20K (1%) | ~80K (4%) |
| FFs | 985K | ~15K (1.5%) | ~60K (6%) |
| BRAM36K | 967 | ~14 (1.4%) | ~56 (5.8%) |
| DSP58 | 1,968 | ~8 (0.4%) | ~32 (1.6%) |
| AIE Tiles | 400 | 0 | ~48 (12%) |

*Estimates based on per-module utilization from Zynq-7000 synthesis, scaled
for Versal. Actual numbers will differ -- we need someone with a VCK190 to
run synthesis and report back.*

## Directory Structure

```
versal-reasoning-fabric/
  Makefile                     # sim-lane, lint, vivado-project, aie-compile
  pl/
    src/
      versal_config.svh        # Deployment constants (lanes, clocks, types)
      versal_top.sv            # Top-level PL module
      lane_tile.sv             # Single reasoning lane
      embedding_projector.sv   # Dimensionality reduction
      instrument_bridge.sv     # Lab instrument adapter
      fabric/                  # Stream routing
      safety/                  # Safety supervisor + kernel + CBF
      compute/                 # RC core + Bicky inference
      plugins/                 # Plugin interface
      common/                  # Timestamp, crypto
    constraints/               # Timing constraints
    tb/                        # Testbenches
  aie/
    src/kernels/               # AIE C++ compute kernels
    src/graphs/                # AIE dataflow graphs
    Makefile                   # AIE compilation
  scripts/
    create_project.tcl         # Vivado project creation
  docs/
    ARCHITECTURE.md            # Block diagram and data flow
  filelists/
    pl_sources.f               # Self-contained source list
```

## How to Help

We're looking for collaborators in three areas:

**1. Hardware validation (most needed).** If you have a VCK190, please:
- Run `make vivado-project` and attempt synthesis
- Report utilization and timing results
- Try the AIE kernels with `aiecompiler`

**2. Instrument bridges.** Implement protocol adapters for specific lab
instruments. The `instrument_bridge.sv` is the framing layer; the protocol
conversion (SCPI/LXI/VISA -> AXI-Stream) is the missing piece.

**3. Agent orchestration software.** The hardware fabric needs a software
orchestration layer (extending the proven [bicky-bee](https://github.com/TidewaterAI/bicky-bee)
NATS/OPA stack) to manage lanes, route agent tasks, and enforce policies.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Background

This project implements ideas from the research document
[Parallel Reasoning Fabric](docs/PARALLEL_REASONING_FABRIC.md) -- a study
of how sensor-processing FPGA architectures generalize to AI agent
orchestration and instrumented lab automation.

The key architectural primitives (stream router, safety supervisor, CBF
solver, plugin interface) were developed for the
[TWAI](https://github.com/TidewaterAI/twai) cyber-physical platform and
proven on Zynq-7000 hardware running the
[bicky-bee](https://github.com/TidewaterAI/bicky-bee) beehive monitoring
pipeline. This project takes those proven modules and scales them to Versal.

## License

Apache 2.0. See [LICENSE](LICENSE).

Copyright 2026 Hampton Roads Research Corporation, LLC.
