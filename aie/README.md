# AIE Kernels — EXPERIMENTAL

> **Status: Untested draft.** These kernels are designed for the Versal AI
> Engine but have not been compiled with `aiecompiler` or validated on
> hardware. They represent the target architecture for Phase 2/3 of the
> reasoning fabric.

## What's Here

| File | Purpose | Status |
|------|---------|--------|
| `kernels/matvec_q15.{h,cc}` | Q1.15 matrix-vector multiply using AIE SIMD | Draft |
| `kernels/rc_update.{h,cc}` | Tanh activation + leaky integration | Draft |
| `graphs/rc_graph.h` | Per-lane RC dataflow graph | Draft |
| `graphs/reasoning_graph.h` | Multi-lane top-level graph | Draft |

## To Validate

Requires:
- Vitis 2023.2+ with VCK190 platform support
- `aiecompiler` and `aiesimulator` in PATH

```bash
make aie-compile    # Compile AIE graph
make aie-sim        # Run AIE simulation with test vectors
```

## Architecture

Each AIE kernel processes a tile (ROW_TILE=32 rows) of the weight matrix.
A full 256-node reservoir requires ceil(256/32) = 8 tile invocations per
matrix. With W_in and W_res matrices, each lane uses ~16 matvec invocations
plus the rc_update activation step.

At 1 GHz AIE clock with 8-wide SIMD, each matvec tile takes ~0.5 us.
A full 256-node RC update takes ~8 us on AIE vs. ~50 us in PL.

## Contributing

If you have access to a VCK190 and can test these kernels, please open an
issue with your results. We're particularly interested in:
- `aiecompiler` success/failure on the graph
- Numerical parity with the PL-side `rc_core.sv` (golden vectors in tests/)
- Resource utilization (AIE tiles used per lane)
