# Versal Reasoning Fabric Architecture

## Block Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         XCVC1902 (VCK190)                          │
│                                                                     │
│  ┌──────────────────────────────────┐                               │
│  │    PS (CIPS)                     │                               │
│  │    A72 (weight loader,           │                               │
│  │         lane manager,            │                               │
│  │         instrument ctrl)         │                               │
│  │    R5F (real-time safety mon)    │                               │
│  └────────────┬─────────────────────┘                               │
│               │ AXI / NoC                                           │
│  ┌────────────v─────────────────────────────────────────────────┐   │
│  │                     PL Fabric (versal_top.sv)                │   │
│  │                                                               │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │   │
│  │  │Lane Tile│  │Lane Tile│  │Lane Tile│  │Lane Tile│        │   │
│  │  │   0     │  │   1     │  │   2     │  │   3     │        │   │
│  │  │         │  │         │  │         │  │         │        │   │
│  │  │ rc_core │  │ rc_core │  │ rc_core │  │ rc_core │        │   │
│  │  │ bicky   │  │ bicky   │  │ bicky   │  │ bicky   │        │   │
│  │  │ safety_k│  │ safety_k│  │ safety_k│  │ safety_k│        │   │
│  │  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘        │   │
│  │       │            │            │            │              │   │
│  │  ┌────v────────────v────────────v────────────v──────────┐   │   │
│  │  │  versal_stream_fabric (9:1 priority router)          │   │   │
│  │  │  4 lanes + 4 instruments + 1 host DMA = 9 inputs     │   │   │
│  │  └────────────────────────┬─────────────────────────────┘   │   │
│  │                           │                                 │   │
│  │  ┌──────────┐  ┌─────────┴──────────┐  ┌─────────────┐    │   │
│  │  │ safety_  │  │  DMA egress (S2MM) │  │ timestamp   │    │   │
│  │  │supervisor│  │  → PS → NATS       │  │ counter     │    │   │
│  │  │ (global) │  └────────────────────┘  │ (PTP/PPS)   │    │   │
│  │  └──────────┘                          └─────────────┘    │   │
│  │                                                               │   │
│  │  ┌──────────────────────────────────────────────────────┐    │   │
│  │  │  Instrument Bridges (FMC+ / QSFP28)                 │    │   │
│  │  │  instr_bridge[0]: Oscilloscope                       │    │   │
│  │  │  instr_bridge[1]: Spectrum Analyzer                  │    │   │
│  │  │  instr_bridge[2]: VNA                                │    │   │
│  │  │  instr_bridge[3]: Thermal Camera                     │    │   │
│  │  └──────────────────────────────────────────────────────┘    │   │
│  └───────────────────────────────────────────────────────────────┘   │
│               │ PLIO (Phase 3)                                      │
│  ┌────────────v──────────────────────────────────────────────────┐  │
│  │                    AI Engine Array                             │  │
│  │                                                                │  │
│  │  ┌──────────────┐  ┌──────────────┐       ┌──────────────┐   │  │
│  │  │ RC Lane 0    │  │ RC Lane 1    │  ...  │ RC Lane N    │   │  │
│  │  │ matvec_win   │  │ matvec_win   │       │ matvec_win   │   │  │
│  │  │ matvec_wres  │  │ matvec_wres  │       │ matvec_wres  │   │  │
│  │  │ rc_update    │  │ rc_update    │       │ rc_update    │   │  │
│  │  └──────────────┘  └──────────────┘       └──────────────┘   │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    DDR4 (via NoC)                             │   │
│  │  Weight storage: 512 KB per lane (RC + Bicky matrices)       │   │
│  │  Instrument buffers: configurable per instrument type         │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

## Data Flow

```
Feature input (from PS DMA or instrument):
  → mm2s AXI-Stream (64-bit, 250 MHz)
    → lane_tile[i] (broadcast to enabled lanes)
      → rc_core or bicky_inference (mode-selected)
        → per-lane safety_kernel (CBF constraint check)
          → plugin_if output (type-tagged AXI-Stream)
            → versal_stream_fabric (priority arbitration)
              → s2mm AXI-Stream → PS DMA → NATS
```

## Clock Domains

| Domain | Frequency | Source | Scope |
|--------|-----------|--------|-------|
| clk_pl | 250 MHz | CIPS pl_clk0 | All PL logic |
| AIE clk | 1 GHz | Silicon fixed | AI Engine tiles |
| NoC clk | Variable | NoC controller | Memory interfaces |
| PPS | 1 Hz | External | Timestamp sync |

All PL logic runs in a single clock domain (clk_pl), matching the Zybo
design philosophy. CDC between PL and AIE is handled by the PLIO interfaces.

## Safety Architecture

```
Global safety_supervisor
  ├── Inputs: kill_ext, any_lane_valid_tick (watchdog)
  ├── Output: global_kill_latched → broadcast to all lane_tiles
  └── Duty accounting: aggregated across all lanes

Per-lane safety_kernel (inside each lane_tile)
  ├── CBF solver: velocity/acceleration/geofence constraints
  ├── Output: lane_fault → OR'd into fabric_fault
  └── Intervention: can suppress lane output independently
```

## Module Transfer Map

| Zybo Module | Versal Module | Status |
|------------|--------------|--------|
| hub_top.v | versal_top.sv | Redesigned for N lanes |
| hub_config.svh | versal_config.svh | New parameters |
| hub_stream_fabric.sv | versal_stream_fabric.sv | Scaled to N inputs |
| safety_supervisor.v | (shared) | No changes |
| safety_kernel.sv | (shared) | No changes |
| cbf_solver.sv | (shared) | No changes |
| stream_router.sv | (shared) | No changes |
| modality_plugin_if.sv | (shared) | No changes |
| rc_core.sv | (shared, Phase 1) | Replaced by AIE in Phase 3 |
| bicky_inference.sv | (shared, Phase 1) | Replaced by AIE in Phase 3 |
| timestamp_counter.v | (shared) | No changes |
| crypto_signer.sv | (shared) | No changes |
| ad7124_reader.sv | instrument_bridge.sv | Generalized |
| hub_rc_mode_fabric.sv | lane_tile.sv (internal mux) | Simplified per-lane |
| — (new) | lane_tile.sv | New: per-lane wrapper |
| — (new) | embedding_projector.sv | New: dimensionality reduction |
| — (new) | instrument_bridge.sv | New: lab equipment adapter |
| — (new) | matvec_q15.cc | New: AIE SIMD compute |
| — (new) | rc_update.cc | New: AIE activation + integration |
