# Contributing

We welcome contributions, especially from anyone with access to AMD Versal
hardware (VCK190 or similar).

## What We Need Most

1. **Hardware validation** — Synthesize the PL fabric on a VCK190 and report
   utilization and timing results.
2. **AIE kernel testing** — Compile the AIE kernels with `aiecompiler` and
   validate numerical parity against the PL-side `rc_core.sv` golden vectors.
3. **Instrument bridges** — Implement protocol adapters for specific lab
   instruments (oscilloscopes, VNAs, spectrum analyzers).
4. **Documentation** — Improve architecture docs, add diagrams, write tutorials.

## Development Setup

```bash
git clone https://github.com/tidewater-ai/versal-reasoning-fabric
cd versal-reasoning-fabric

# Simulation (requires Icarus Verilog)
make sim-lane    # Should print "PASS" for all tests

# Lint (requires Verilator)
make lint
```

## Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Run simulation (`make sim-lane`) and verify it passes
5. Open a pull request with a clear description

## Code Style

- **SystemVerilog**: 4-space indent, `_snake_case` for signals, `UPPER_CASE`
  for parameters and localparams
- **Safety chain modules** (`safety/`): Do not modify without discussion.
  These are Ring-0 safety-critical logic.
- **Q1.15 arithmetic**: Any new fixed-point path must include saturation and
  be roundtrip-tested against the Python reference.

## Architecture

See `docs/ARCHITECTURE.md` for the block diagram and data flow.

The key abstraction is the `modality_plugin_if` interface — every lane tile
exposes this interface to the fabric. If you're adding a new compute module,
wrap it in a plugin that implements this interface.

## License

By contributing, you agree that your contributions will be licensed under
the same Apache 2.0 license as the project.
