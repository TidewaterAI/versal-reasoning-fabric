# From Sensor Streams to Reasoning Streams: A Parallel Hardware Fabric for AI Agent Orchestration

**TWAI Research Document -- April 2026**
**Hampton Roads Research Corporation, LLC**

---

## Abstract

The TWAI platform currently implements a closed-loop cyber-physical pipeline
where ADC sensor data flows through FPGA-resident processing blocks (reservoir
computing, feedforward neural inference, safety gating, cryptographic signing)
before reaching software-layer policy and reasoning services. This document
explores a fundamental generalization: replacing sensor data with AI reasoning
streams -- token sequences, embedding vectors, code AST fragments, tool
outputs, and agent state -- and scaling the existing FPGA fabric into a
massively parallel hardware substrate for multi-agent orchestration.

We analyze the architectural homomorphism between the current hive monitoring
pipeline and a hypothetical agent reasoning pipeline, propose concrete hardware
and software architectures for both FPGA prototyping and eventual ASIC
implementation, and examine the recursive case: a system-on-chip that
participates in designing its own successor.

---

## 1. The Architectural Homomorphism

### 1.1 Current Pipeline (Hive Monitoring V1)

The existing TWAI data flow on the Zybo Z7-20 is:

```
AD7124 ADC (SPI, Q8.24, DRDY-triggered)
  |
  v  64-bit AXI-Stream
array_ingest (window gating, duration control)
  |
  v
ad7124_reader (SPI capture -> timestamped ArrayWindow frames)
  |
  v
hub_stream_fabric (2-slot priority mux, stream_router N:1)
  |
  +---> rc_core (256-node reservoir, Q1.15, tanh LUT, leaky update)
  |       |
  |       v  64-bit AXI-Stream (rho, alpha, checksum, feature_sum)
  |     hub_rc_mode_fabric (RC/Bicky mode switch)
  |
  +---> bicky_inference (feedforward NN: input->hidden tanh->output linear)
  |       |  13->256->5 (Q1.15, DSP48 mul_q15)
  |       v  64-bit AXI-Stream (4x Q1.15 packed per beat)
  |     hub_rc_plugin_bridge (status/debug fanout)
  |
  v
safety_supervisor (watchdog, kill latch, duty counter)
  + safety_kernel (CBF solver: velocity/acceleration/geofence limits)
  |
  v
crypto_signer (SHA-256/Ed25519 frame signing)
  |
  v  AXI-Stream -> DMA -> PS Linux -> NATS
Lex Kernel (3-tier: ANE <1ms, MoE 397B ~5 tok/s, OPA policy)
```

**Key architectural primitives:**

| Primitive | RTL Module | Bus Width | Function |
|-----------|-----------|-----------|----------|
| Ingest & Window | `array_ingest`, `ad7124_reader` | 64b AXI-S | Capture, timestamp, frame |
| Parallel Compute | `rc_core`, `bicky_inference` | 64b AXI-S | Transform input -> output |
| Routing Fabric | `stream_router`, `hub_rc_mode_fabric` | 64b, N:1 | Priority arbitration, mode switch |
| Safety Gate | `safety_supervisor`, `safety_kernel` | 32b signals | Hard limits, kill latch, CBF projection |
| Feature Extract | `dsp_feature_edge` | 16b in, 24b out | Sliding window RMS/abs |
| Provenance | `crypto_signer` | 64b + 64b sig | Frame authentication |
| Config/Weights | AXI-Lite registers | 16b Q1.15 | Weight load, parameter set |

### 1.2 The Isomorphism to Agent Reasoning

Every primitive in the sensor pipeline has a direct analogue in multi-agent
reasoning:

| Sensor Pipeline | Agent Reasoning Pipeline |
|----------------|--------------------------|
| ADC sample (Q8.24 scalar) | Token embedding (float16/bfloat16 vector) |
| Microphone channel | Agent input stream (code, context, tool output) |
| Window gating (array_ingest) | Context window management (sliding attention window) |
| Feature extraction (dsp_feature_edge) | Embedding projection / dimensionality reduction |
| RC core (reservoir state update) | Associative memory / working memory update |
| Bicky inference (feedforward classify) | Expert routing / task classifier |
| stream_router (N:1 priority mux) | Agent output arbiter (which agent's output wins) |
| hub_rc_mode_fabric (RC/Bicky switch) | Expert/specialist selection fabric |
| safety_supervisor (kill latch) | Reasoning policy gate (halt runaway chains) |
| safety_kernel + CBF solver | Reasoning safety barrier (output constraint projection) |
| crypto_signer (frame signing) | Audit trail / chain-of-thought provenance |
| DMA to PS | High-bandwidth result extraction to orchestrator |
| NATS subjects | Agent coordination channels |
| OPA/Rego policy | Agent action authorization |

This is not mere analogy. The data flow is structurally identical:

```
Input streams (N channels)
  -> Ingest & frame (timestamped windows)
    -> Parallel processing cores (M instances)
      -> Routing fabric (arbitration, priority)
        -> Safety gate (hard limits)
          -> Output with provenance
            -> Software orchestration layer
```

The key difference is scale: hive monitoring uses 2 input lanes and 2
processing cores on an 8.8% LUT-utilized Zybo Z7-20. A reasoning fabric
would target hundreds or thousands of parallel lanes on a substantially
larger device.

---

## 2. Software Architecture: Orchestrating Agent Teams

### 2.1 Current Software Stack as Agent Infrastructure

The existing TWAI software stack already implements most of what a multi-agent
orchestration system needs:

**NATS JetStream as Agent Bus.** The current subject hierarchy
(`twai.kernel.state.v1`, `twai.kernel.reasoning.v1`, `hive.features.v1`,
`safety.events`) maps directly to agent communication channels. Each agent
gets a subject namespace; the JetStream persistence gives replay and audit
for free. The existing `tiles_ack` pattern (command -> policy gate ->
ack/reject) is exactly the pattern needed for agent action approval.

**3-Tier Inference as Agent Cognition Hierarchy.** The Lex kernel's three
tiers map to a natural agent reasoning hierarchy:

| Tier | Current Use | Agent Analogue | Latency |
|------|-------------|----------------|---------|
| Tier 1 (ANE, Bicky) | 13->256->5 classification | Fast reflexive routing: which agent handles this? | <1ms |
| Tier 2 (ANE, RC readout) | 256->5 reservoir output | Working memory query: what does the context say? | <1ms |
| Tier 3 (Flash-MoE 397B) | Full LLM reasoning | Deep deliberation: complex multi-step reasoning | 50-200ms |

**OPA Policy as Agent Authorization.** The existing Rego policy engine
(currently enforcing ABORT/HOLD/ADVANCE cascades for hive safety) generalizes
to agent action policies: which tools can this agent call? What data can it
access? Can it modify code? Can it spawn sub-agents?

**HMAC Audit Ledger as Chain-of-Thought Provenance.** The existing
`TWAIAuditLedger` with HMAC-SHA256 chaining provides exactly the tamper-proof
reasoning trace needed for multi-agent accountability.

### 2.2 Proposed Agent Orchestration Architecture

```
                    +----------------------------------+
                    |     Agent Coordination Layer      |
                    |  (extends TWAIOrchestrator)       |
                    +----------------------------------+
                           |              |
              +------------+              +------------+
              |                                        |
    +---------v----------+              +--------------v-------+
    | Agent Registry     |              | Task Router          |
    | (who can do what)  |              | (Tier 1: fast route) |
    | - capabilities     |              | - ANE classifier     |
    | - resource limits  |              | - embedding match    |
    | - trust level      |              | - priority queue     |
    +--------------------+              +----------------------+
              |                                        |
              v                                        v
    +---------------------------------------------------+
    | Agent Pool (N concurrent agents)                  |
    |                                                   |
    | +--------+ +--------+ +--------+     +--------+  |
    | |Agent 0 | |Agent 1 | |Agent 2 | ... |Agent N | |
    | |code    | |test    | |review  |     |design  | |
    | |writer  | |runner  | |er      |     |er      | |
    | +---+----+ +---+----+ +---+----+     +---+----+ |
    |     |          |          |               |      |
    +---------------------------------------------------+
              |          |          |               |
              v          v          v               v
    +---------------------------------------------------+
    | Reasoning Fabric Interface                        |
    | (extends TWAIFPGABridge)                          |
    |                                                   |
    | Each agent's reasoning stream is a "channel"      |
    | analogous to an ADC channel.                      |
    |                                                   |
    | Agent output -> Q1.15 embedding -> FPGA ingest    |
    | FPGA result -> priority arbitration -> DMA out    |
    +---------------------------------------------------+
              |
              v
    +---------------------------------------------------+
    | Hardware Reasoning Fabric (FPGA / ASIC)           |
    | (scaled hub_top with N lanes)                     |
    |                                                   |
    | N x rc_core (working memory / pattern matching)   |
    | N x bicky_inference (expert routing)              |
    | N x dsp_feature_edge (embedding projection)       |
    | 1 x stream_router (N:1, priority-based)           |
    | 1 x safety_supervisor (global kill)               |
    | N x safety_kernel (per-agent CBF)                 |
    | 1 x crypto_signer (provenance)                    |
    +---------------------------------------------------+
              |
              v
    +---------------------------------------------------+
    | Policy & Reasoning Layer                          |
    | (extends TWAIOPAEvaluator + TWAIReasoningService) |
    |                                                   |
    | OPA: per-agent action authorization               |
    | Flash-MoE: deep reasoning for complex decisions   |
    | Audit: HMAC-chained reasoning traces              |
    +---------------------------------------------------+
```

### 2.3 Agent-to-Hardware Stream Mapping

Each agent's reasoning process generates a continuous stream of state that
maps to a hardware channel:

```
Agent reasoning step:
  1. Receive task context      -> Ingest (ad7124_reader analogue)
  2. Encode into embedding     -> Feature extraction (dsp_feature_edge)
  3. Update working memory     -> RC core state update
  4. Classify/route decision   -> Bicky inference
  5. Check safety constraints  -> Safety kernel + CBF
  6. Emit signed result        -> Crypto signer + DMA

In hardware, this is one "lane" of the reasoning fabric.
Running 64 agents = 64 lanes, each with its own RC + Bicky + safety instance.
```

The `stream_router` already supports parameterized `NUM_INPUTS` -- the current
deployment uses 2 (ADC + RC/Bicky), but the module is designed for N. The
priority arbitration logic (lowest numeric priority wins, frame-atomic
forwarding) maps directly to agent output priority.

### 2.4 Software Extensions Required

Mapping the current codebase to agent orchestration requires:

1. **Agent Registry** (new module, extends `hub_config.svh` pattern to software):
   - Agent capabilities, resource quotas, trust levels
   - Maps to hardware lane assignments

2. **Task Router** (extends `TWAIANEInference`):
   - Use the existing ANE 1x1 conv path for fast task-to-agent classification
   - Input: task embedding vector (same 13-dim -> 256-dim -> N-class pattern)
   - Output: agent assignment

3. **Reasoning Fabric Bridge** (extends `TWAIFPGABridge`):
   - Replace UART ADC frame parsing with agent state serialization
   - Same Q1.15 encoding for hardware compatibility
   - Each agent gets a "channel" in the ingest fabric

4. **Agent Policy Rules** (extends `hive.rego`):
   - Per-agent capability rules (analogous to per-sensor safety limits)
   - Cross-agent coordination rules (analogous to multi-channel interlock)
   - Resource budget enforcement (analogous to duty_limit)

5. **Coordination Protocol** (extends NATS subject hierarchy):
   ```
   twai.agent.<id>.state.v1      -- Agent state snapshots
   twai.agent.<id>.reasoning.v1  -- Reasoning chain events
   twai.agent.<id>.output.v1     -- Agent outputs
   twai.fabric.arbitration.v1    -- Who has the floor
   twai.fabric.safety.v1         -- Global reasoning safety events
   ```

---

## 3. Hardware Architecture: The Parallel Reasoning Fabric

### 3.1 Current Resource Budget

The Zybo Z7-20 (XC7Z020) provides:

| Resource | Available | Current Use | Utilization |
|----------|-----------|-------------|-------------|
| LUTs | 53,200 | ~4,682 | 8.8% |
| FFs | 106,400 | ~3,500 (est) | ~3.3% |
| BRAM (36Kb) | 140 | ~20 (est) | ~14% |
| DSP48 | 220 | ~10 (est) | ~4.5% |

A single RC core (256 nodes, 64 features) uses roughly:
- ~800 LUTs (control FSM, tanh LUT, muxing)
- ~600 FFs (state registers, counters)
- ~4 BRAM (win_mem: 256x64=16K x 16b, wres: 256x8=2K x 16b, state: 256 x 16b)
- ~2 DSP48 (mul_q15 operations)

A single Bicky core (256 hidden, 64 feat, 16 output) uses roughly:
- ~1,000 LUTs
- ~800 FFs
- ~6 BRAM (win_mem: 256x64, vout_mem: 16x256, hidden/feat/out memories)
- ~2 DSP48

**On the current Zybo Z7-20**, with 91% LUTs free, we could fit approximately
**20-25 additional RC+Bicky lane pairs** -- enough for a 20-agent prototype
reasoning fabric. BRAM would be the first bottleneck (~20 BRAM per lane pair).

### 3.2 Scaled Fabric on Larger Devices

| Target Device | LUTs | BRAM (36Kb) | DSP48 | Est. Lanes | Use Case |
|---------------|------|-------------|-------|------------|----------|
| Zybo Z7-20 (current) | 53K | 140 | 220 | 2 (current) / 7 (BRAM-limited) | Proof of concept |
| ZCU104 (ZU7EV) | 504K | 312 | 1,728 | ~15 lanes | Development prototype |
| KCU116 (KU5P) | 872K | 1,188 | 2,880 | ~60 lanes | Research platform |
| VCU128 (VU37P) | 2,852K | 4,032 | 9,024 | ~200 lanes | Production prototype |
| Versal VCK190 | 1,968K (AIE+PL) | 967 + AIE | 1,968 + 400 AIE | ~400 lanes (AIE-assisted) | Near-ASIC perf |

The Versal line is particularly interesting because the AI Engine (AIE) tiles
are *already* VLIW vector processors designed for streaming matrix operations --
they could run the RC state update and Bicky matrix-vector products natively
without consuming PL resources.

### 3.3 Proposed RTL Architecture: `reasoning_fabric_top`

```
module reasoning_fabric_top #(
    parameter int NUM_LANES     = 64,    // Number of parallel agent lanes
    parameter int DATAW         = 64,    // AXI-Stream data width
    parameter int QW            = 16,    // Q1.15 fixed-point width
    parameter int RC_NODES      = 256,   // Reservoir nodes per lane
    parameter int RC_FEAT       = 64,    // Features per lane
    parameter int BICKY_HIDDEN  = 256,   // Bicky hidden nodes per lane
    parameter int BICKY_OUT     = 16,    // Bicky output dimension per lane
    parameter int EMBED_DIM     = 128    // Embedding vector dimension
)(
    // Clock and Reset
    input  wire        clk_fabric,       // Fabric clock (e.g., 250 MHz)
    input  wire        clk_agent,        // Agent interface clock (e.g., 100 MHz)
    input  wire        rst_n,

    // Agent Input Streams (NUM_LANES x AXI-Stream)
    input  wire [NUM_LANES*DATAW-1:0]  agent_s_tdata,
    input  wire [NUM_LANES-1:0]        agent_s_tvalid,
    output wire [NUM_LANES-1:0]        agent_s_tready,
    input  wire [NUM_LANES-1:0]        agent_s_tlast,

    // Arbitrated Output Stream (1x AXI-Stream to DMA)
    output wire [DATAW-1:0]            fabric_m_tdata,
    output wire                        fabric_m_tvalid,
    input  wire                        fabric_m_tready,
    output wire                        fabric_m_tlast,

    // Safety
    input  wire                        global_kill,
    output wire [NUM_LANES-1:0]        lane_fault,
    output wire                        fabric_fault,

    // Configuration (AXI-Lite)
    // ... weight load, lane enable, priority assignment ...
);
```

The internal structure generates per-lane processing and connects to
a scaled `stream_router`:

```
    genvar i;
    generate
        for (i = 0; i < NUM_LANES; i++) begin : lane_gen

            // Per-lane embedding projector
            embedding_projector #(.DIM_IN(EMBED_DIM), .DIM_OUT(RC_FEAT))
                u_embed (.clk(clk_fabric), ...);

            // Per-lane RC core (working memory)
            rc_core #(.NODES_MAX(RC_NODES), .FEAT_MAX(RC_FEAT))
                u_rc (.clk(clk_fabric), ...);

            // Per-lane Bicky inference (classifier/router)
            bicky_inference #(.NODES_MAX(BICKY_HIDDEN), .OUT_MAX(BICKY_OUT))
                u_bicky (.clk(clk_fabric), ...);

            // Per-lane safety kernel
            safety_kernel #(.DATAW(32))
                u_safety (.clk(clk_fabric), ...);

        end
    endgenerate

    // Global N:1 stream router with priority arbitration
    stream_router #(
        .DATA_W(DATAW),
        .NUM_INPUTS(NUM_LANES),
        .PRIO_W(8),
        .TYPE_W(8)
    ) u_fabric_router (...);

    // Global safety supervisor
    safety_supervisor u_global_safety (...);

    // Provenance signer
    crypto_signer u_signer (...);
```

### 3.4 The Embedding Projector: New Core IP

The one component that does not exist in the current RTL is a hardware
embedding projector. This is the analogue of `dsp_feature_edge` but for
high-dimensional vectors:

```
module embedding_projector #(
    parameter int DIM_IN  = 128,   // Input embedding dimension
    parameter int DIM_OUT = 64,    // Output feature dimension (matches RC feat_k)
    parameter int QW      = 16     // Q1.15 fixed-point
)(
    input  logic                  clk,
    input  logic                  rst_n,
    // AXI-Stream input (embedding vector, packed QW per beat)
    input  logic [63:0]           s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,
    // AXI-Stream output (projected features)
    output logic [63:0]           m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  logic                  m_axis_tready,
    output logic                  m_axis_tlast,
    // Projection matrix load (DIM_OUT x DIM_IN weights)
    input  logic                  proj_we,
    input  logic [31:0]           proj_addr,
    input  logic signed [QW-1:0]  proj_value
);
    // Matrix-vector multiply: y = W * x
    // where W is DIM_OUT x DIM_IN, x is DIM_IN x 1
    // Computed as DIM_OUT dot products, each of DIM_IN terms
    // Same mul_q15 + accumulate pattern as bicky_inference hidden layer
    // but without the nonlinearity (or with optional ReLU/tanh)
```

This is structurally identical to the Bicky hidden layer computation
(`a = tanh(Win * u)`) -- it is a parameterized matrix-vector multiply with
optional nonlinearity. The existing `mul_q15` DSP48 inference and weight-load
interface transfer directly.

### 3.5 Memory Architecture: The Critical Scaling Challenge

The primary bottleneck for scaling is BRAM. Each RC+Bicky lane pair requires
approximately 20 BRAM36K blocks:

| Memory | Size | BRAM36K |
|--------|------|---------|
| RC win_mem (256x64 x 16b) | 32 KB | 1 |
| RC wres_val (256x8 x 16b) | 4 KB | <1 |
| RC wres_col (256x8 x 16b) | 4 KB | <1 |
| RC state_mem (256 x 16b) | 0.5 KB | <1 |
| RC feat_mem (64 x 16b) | 0.1 KB | <1 |
| Bicky win_mem (256x64 x 16b) | 32 KB | 1 |
| Bicky vout_mem (16x256 x 16b) | 8 KB | <1 |
| Bicky hidden_mem (256 x 16b) | 0.5 KB | <1 |
| Embedding proj matrix (128x64 x 16b) | 16 KB | <1 |
| **Subtotal per lane** | **~100 KB** | **~3** |

For a 64-lane fabric: ~6,400 KB = ~200 BRAM36K. This fits comfortably on
a KCU116 (1,188 BRAM) but is the binding constraint on the Zybo Z7-20 (140 BRAM).

**Optimization strategies:**

1. **Weight sharing across lanes.** If agents share base models, the projection
   and RC weights can be stored once and time-multiplexed. This reduces BRAM by
   ~70% at the cost of throughput.

2. **External memory for weights.** Use DDR for weight storage and a DMA engine
   to page weights into per-lane BRAM as lanes activate. This mirrors the
   Flash-MoE NVMe expert paging strategy -- the same insight at a different
   level of the hierarchy.

3. **Sparse reservoir.** The RC core already supports sparse recurrent
   connections (WRES_SLOTS=8 per node). Reducing density further allows
   smaller memories with minimal accuracy impact.

4. **Reduced precision.** The current Q1.15 (16-bit) can be reduced to Q1.7
   (8-bit) for many agent tasks, halving memory requirements. The Bicky
   `mul_q15` function would become `mul_q7`, using fewer DSP48 resources.

### 3.6 The Crossbar Interconnect: Beyond stream_router

The current `stream_router` is N:1 (many inputs, one output). A full agent
fabric needs N:N (any agent can talk to any other). This requires a crossbar:

```
                      Agent 0  Agent 1  Agent 2  ...  Agent N
                        |        |        |              |
                        v        v        v              v
                   +------------------------------------------+
                   |        Crossbar Switch Fabric            |
                   |  (time-multiplexed AXI-Stream matrix)    |
                   |                                          |
                   |  Each cycle: one granted transfer        |
                   |  Priority: round-robin or weighted       |
                   |  Atomic: frame-level (TLAST boundary)    |
                   +------------------------------------------+
                        |        |        |              |
                        v        v        v              v
                      Agent 0  Agent 1  Agent 2  ...  Agent N

Also: dedicated DMA output port for PS/host extraction
Also: dedicated safety broadcast channel (all lanes hear kill)
```

This can be built from the existing `stream_router` by instantiating N output
routers, one per destination lane, with the input ports connected to all source
lanes. The existing priority arbitration and frame-atomic forwarding logic
transfers unchanged.

For a 64-lane fabric, a full crossbar is 64x64 = 4,096 switch points, but
most agent communication is sparse (an agent talks to 2-3 others, not all 63).
A **sparse crossbar** with configurable routing tables (analogous to the
`slot_enable` mask in `stream_router`) reduces this dramatically.

---

## 4. The Self-Designing SoC

### 4.1 The Recursive Architecture

The most profound implication of this work is the recursive case: if the
hardware fabric accelerates agent reasoning, and agents can design hardware,
then the system can participate in designing its own improvements.

```
Cycle 0: Human designs initial FPGA fabric (current state)
         -> Agents run on software (current state)

Cycle 1: Agents + FPGA fabric jointly explore design space
         -> Agent team generates RTL candidates
         -> FPGA fabric evaluates candidates (fast simulation)
         -> Best candidates synthesized and evaluated

Cycle 2: Improved fabric runs improved agents
         -> Agents generate better RTL
         -> Faster/more parallel evaluation
         -> Stronger candidates emerge

Cycle N: Convergence to a self-optimized architecture
```

This is not science fiction. The TWAI platform already has the components:

1. **Agent-generated RTL.** LLM agents (via Flash-MoE Tier 3 reasoning) can
   generate SystemVerilog. The existing `rc_core.sv`, `bicky_inference.sv`,
   and `stream_router.sv` serve as few-shot examples of the architectural
   style.

2. **Automated synthesis feedback.** The Vivado flow is scriptable (TCL).
   An agent can run synthesis, read timing reports, and iterate. The existing
   `create_project.tcl` and bitstream build flow demonstrate this.

3. **Hardware-in-the-loop evaluation.** The existing `tests/sim/` Verilator
   testbenches and `tests/hil/` hardware-in-the-loop framework provide the
   evaluation pipeline. An agent generates RTL, simulates it, and measures
   quality.

4. **Evolutionary optimization.** The existing `twai-evolve` hyperagent bench
   (Phase 1 complete, 29 tests passing) implements population-based
   optimization with mutation and selection. Extending it to RTL parameters
   (lane count, node count, precision, sparsity) is a natural step.

### 4.2 What the Agents Would Optimize

| Design Parameter | Current Value | Optimization Target |
|-----------------|---------------|---------------------|
| RC nodes per lane | 256 | Minimize nodes while maintaining accuracy |
| Feature dimensions | 64 | Match to actual agent embedding dim |
| Bicky hidden size | 256 | Right-size for routing accuracy |
| Q format | Q1.15 (16-bit) | Find minimum precision per task |
| Sparsity (WRES_SLOTS) | 8 | Optimize connectivity vs. memory |
| Lane count | 2 | Maximize given device constraints |
| Clock frequency | 100 MHz | Push timing closure |
| Crossbar topology | N:1 (current) | Sparse N:N with measured traffic |
| Tanh LUT size | 64 entries | Accuracy vs. area tradeoff |
| Pipeline depth | 3-stage (capture/update/output) | Throughput vs. latency |
| Weight precision | 16-bit | Mixed precision per layer |
| Memory architecture | Distributed BRAM | Shared + paged vs. per-lane |

### 4.3 The SoC Learning Loop

For eventual ASIC tapeout, the design loop becomes:

```
1. DEFINE the agent workload (what kinds of reasoning, what data rates)
   -> Profiling from FPGA prototype operation

2. GENERATE candidate architectures
   -> Agents produce RTL + floorplan constraints
   -> Guided by measured FPGA resource utilization

3. EVALUATE candidates
   -> Gate-level simulation for correctness
   -> Synthesis for area/timing/power estimates
   -> FPGA prototyping for real workload performance

4. SELECT and REFINE
   -> twai-evolve population-based optimization
   -> Pareto front: throughput vs. power vs. area

5. TAPE OUT
   -> OpenLane / OpenROAD flow for open-source silicon
   -> Or commercial foundry for production

6. MEASURE real silicon performance
   -> Feed back into step 1 for next generation
```

The TWAI project already targets openXC7 for FPGA synthesis (documented in
`docs/ops/`). The path from openXC7 to OpenLane for ASIC tapeout is
architecturally straightforward -- the RTL is the same, the backend tools
change.

---

## 5. Concrete Implementation Plan

### 5.1 Phase 1: Software Prototype (No Hardware Changes)

**Goal:** Validate the agent orchestration architecture in software, using the
existing FPGA as a co-processor for fast classification.

**Changes:**

- Extend `TWAIOrchestrator` with agent registry and task router
- Add NATS subjects for agent coordination (`twai.agent.*`)
- Use existing ANE Tier 1 path for fast task routing (retrain Bicky with
  task embeddings instead of acoustic features)
- Use existing Flash-MoE Tier 3 for agent reasoning
- Add OPA rules for agent authorization
- Extend audit ledger for multi-agent traces

**Timeline:** Incremental, builds on existing stack. No new hardware.

### 5.2 Phase 2: Scaled FPGA Prototype

**Goal:** Implement multi-lane reasoning fabric on a larger FPGA.

**Hardware Target:** ZCU104 (ZU7EV) or KCU116 -- enough BRAM for 15-60 lanes.

**Changes:**

- Generalize `hub_config.svh` for configurable lane count
- Instantiate `rc_core` + `bicky_inference` arrays (N lanes)
- Implement `embedding_projector` core
- Scale `stream_router` to N inputs
- Per-lane `safety_kernel` instances
- Shared weight memory with DMA paging (mirrors Flash-MoE NVMe strategy)
- New `reasoning_fabric_top` wrapper

**Key Insight:** The existing `hub_top.v` Phase 3 shell-thinning work (which
extracted `hub_stream_fabric`, `hub_safety_fabric`, `hub_timing_fabric`,
`hub_rc_mode_fabric`, etc. into independent modules) was *exactly* the
refactoring needed to make these modules composable for a scaled fabric.
The modularization work already done is the foundation.

### 5.3 Phase 3: Self-Designing Loop

**Goal:** Close the design loop where agents optimize their own hardware.

**Components:**

- RTL generation agent (produces SystemVerilog from architectural specs)
- Synthesis evaluation agent (runs Vivado TCL, parses reports)
- Simulation agent (runs Verilator testbenches, measures correctness)
- twai-evolve integration (population-based architecture search)
- Human review gate (all tapeout decisions require human approval --
  safety ring 2 policy enforcement)

### 5.4 Phase 4: ASIC Tapeout

**Goal:** Produce a custom chip optimized for parallel agent reasoning.

**Approach:** Use the FPGA-validated RTL as the starting point. The
OpenLane/OpenROAD flow takes the same Verilog/SystemVerilog source.

**Key architectural decisions for silicon:**
- Fixed lane count (optimized from Phase 3 exploration)
- Hardened MAC units (replacing DSP48 soft multipliers)
- SRAM macro blocks (replacing BRAM inference)
- On-chip network (replacing crossbar with NoC for >64 lanes)
- Dedicated weight cache with prefetch (replacing DMA)

---

## 6. Theoretical Foundations

### 6.1 Why Hardware Acceleration for Agent Reasoning?

LLM inference (Tier 3) is already GPU/Metal-accelerated. The value of FPGA/ASIC
acceleration is not in replacing the LLM, but in accelerating the *orchestration
layer* -- the decisions about what to reason about, which agent should handle
what, and whether the result is safe.

The latency breakdown in a multi-agent system:

| Operation | Current (Software) | With Reasoning Fabric |
|-----------|-------------------|----------------------|
| Task classification | 5-10ms (Python) | <1ms (FPGA Bicky) |
| Agent selection | 2-5ms (Python) | <1ms (FPGA priority mux) |
| Context window assembly | 10-50ms (Python) | 2-5ms (FPGA DMA) |
| Working memory query | 5-20ms (Python) | <1ms (FPGA RC readout) |
| Safety check | 2-5ms (OPA eval) | <0.1ms (FPGA CBF) |
| **Orchestration overhead** | **24-90ms** | **<5ms** |
| Deep reasoning (LLM) | 50-200ms | 50-200ms (unchanged) |

The reasoning fabric doesn't replace the LLM -- it replaces the orchestration
overhead that surrounds each LLM call. For a system running 64 agents with
rapid turn-taking, reducing orchestration from 90ms to 5ms is the difference
between agents that feel sequential and agents that feel parallel.

### 6.2 Reservoir Computing as Agent Working Memory

The RC core is particularly well-suited to agent state tracking because
reservoir computing inherently maintains a compressed temporal trace. The
leaky update equation:

```
state[n] = (1-alpha) * state[n-1] + alpha * tanh(W_in * input + W_res * state[n-1])
```

...creates a fading memory where recent inputs have strong influence and older
inputs decay exponentially. This is *exactly* the behavior needed for an
agent's working memory: recent context matters most, old context fades, and
the reservoir naturally compresses a variable-length history into a
fixed-dimensional state vector.

The current rc_core with 256 nodes and Q1.15 precision provides 256 x 16 bits
= 4,096 bits = 512 bytes of compressed temporal state. This is small by LLM
standards but rich enough for routing decisions, safety classification, and
pattern detection -- the fast reflexive layer that decides *whether* to invoke
expensive LLM reasoning.

### 6.3 The Bicky Classifier as Expert Router

The Bicky inference core (`a = tanh(W_in * u); z = V * a`) is a single-hidden-
layer feedforward network. In the current system, it classifies acoustic states
into 5 classes (quiet/foraging/waggle/piping/alarm). In the reasoning fabric,
the same architecture classifies agent states into routing decisions:

- Which agent should handle this task?
- What priority should this agent's output receive?
- Does this reasoning chain need human review?
- Should this agent spawn sub-agents?

The 13->256->5 architecture (13 features, 256 hidden, 5 outputs) runs in
microseconds on the FPGA. Scaling to 128->256->64 (128-dim embeddings, 64
possible routing destinations) requires only slightly more BRAM and the same
compute structure.

---

## 7. Open Questions

1. **What is the right embedding dimension for agent state?** The current
   13-dim acoustic feature vector is domain-specific. Agent reasoning state
   is higher-dimensional. Is 128 sufficient? 256? Does it depend on the task?

2. **How do you quantize reasoning to Q1.15?** Acoustic signals are naturally
   bounded. Agent embeddings may not be. Normalization strategy matters.

3. **What is the minimum RC reservoir size for effective agent routing?**
   256 nodes works for 5-class acoustic classification. How many classes
   (routing decisions) can it handle before accuracy degrades?

4. **How fast can agents actually iterate on RTL?** The Vivado synthesis
   loop is 10-60 minutes. Can agents make meaningful progress with that
   feedback latency? (Verilator simulation is seconds -- use simulation
   for exploration, synthesis for validation.)

5. **What is the power budget?** An ASIC for agent reasoning needs to be
   power-efficient to be practical. The current FPGA fabric at 8.8% LUT
   utilization draws ~2W. A 200-lane fabric on a VU37P might draw 50-100W.
   A custom ASIC could be 10-20x more efficient.

6. **How do you handle non-determinism?** The current FPGA pipeline is fully
   deterministic (same input -> same output). LLM reasoning is inherently
   stochastic. Where in the pipeline does non-determinism enter, and how
   does the safety fabric handle it?

7. **Intellectual property considerations for self-generated RTL.** If agents
   generate novel RTL, who owns the IP? How is it verified for correctness
   and safety before tapeout?

---

## 8. Relationship to Prior Art

- **Cerebras CS-2 / Wafer-Scale Engine:** Massively parallel compute for ML
  training/inference. Different goal (raw FLOPS) but similar insight (spatial
  parallelism for ML workloads).

- **Graphcore IPU:** Intelligence Processing Unit with bulk synchronous parallel
  execution. The TWAI reasoning fabric is closer to this model than to GPU
  architectures, because agents execute in coordinated phases.

- **Google TPU:** Systolic array for matrix multiplication. The Bicky/RC
  compute pattern is a specialized systolic operation.

- **Groq LPU:** Deterministic inference with known-at-compile-time scheduling.
  The TWAI safety kernel's tick_budget enforcement is a similar idea -- bounded
  compute time guarantees.

- **SambaNova SN40L:** Reconfigurable dataflow architecture. The TWAI
  reasoning fabric with configurable lane parameters (via AXI-Lite register
  bank) is a simpler version of this idea.

- **RISC-V + custom accelerators:** The open-source silicon path (OpenLane)
  aligns with the RISC-V ecosystem. A TWAI reasoning fabric ASIC could include
  a RISC-V core for control plane and custom accelerator lanes for reasoning.

---

## 9. Summary

The TWAI platform's existing FPGA architecture -- streaming ingest, parallel
RC/Bicky processing, priority-based routing, safety gating, and cryptographic
provenance -- is structurally isomorphic to what a multi-agent reasoning
fabric requires. The sensor data pipeline and the reasoning data pipeline
differ in content (ADC samples vs. token embeddings) but not in architecture
(windowed streams through parallel processing cores with safety constraints).

The modularization work already completed in Phase 3 (extracting `hub_stream_fabric`,
`hub_safety_fabric`, `hub_timing_fabric`, `hub_rc_mode_fabric`, and the plugin
system) was precisely the refactoring needed to make these components composable
at scale. The `stream_router` is already parameterized for N inputs. The
`rc_core` and `bicky_inference` are already parameterized for configurable
dimensions. The safety architecture already supports per-module and global
kill paths.

The path from here is incremental:
1. Software-only agent orchestration using existing hardware (now)
2. Multi-lane FPGA prototype on a larger device (near-term)
3. Agent-driven hardware optimization loop (medium-term)
4. Custom ASIC tapeout with agent-optimized architecture (long-term)

At each stage, the system becomes better at designing the next stage. This
is the recursive promise: hardware that accelerates the reasoning that
designs better hardware.

---

## 10. The Instrumented Lab: Closing the Full Loop

### 10.1 The Missing Piece

Sections 1-9 describe a system that designs hardware and reasons about
designs. But hardware design does not end at tapeout or bitstream generation.
The real feedback loop includes **physical characterization**: probing the
actual silicon or FPGA, measuring its behavior with real instruments, and
feeding those measurements back to the agents that designed it.

The TWAI architecture is already built for this. The hive monitoring system
ingests multi-modal sensor streams (acoustic, e-field, thermal) through ADCs
and processes them in real time. A chip design lab is the same problem at a
different scale: instead of microphones and capacitive plates, the sensors
are oscilloscopes, spectrum analyzers, logic analyzers, VNAs, probe stations,
thermal cameras, power analyzers, and SEM imagers. Instead of bee behavior
classification, the inference task is silicon characterization.

### 10.2 Lab Instrument Streams as ADC Channels

Every modern lab instrument has a digital output interface. The mapping to
the TWAI ingest architecture is direct:

| Lab Instrument | Data Format | Analog to TWAI |
|----------------|-------------|----------------|
| **Oscilloscope** (Rigol/Keysight/Tek) | SCPI over LXI/VISA, waveform arrays (float32/int16) | AD7124 ADC channel (time-domain samples) |
| **Spectrum analyzer** | SCPI, frequency-domain arrays | E-field DSP (spectral features) |
| **Logic analyzer** (Saleae/Digilent) | Digital capture, protocol decode | Trigger bus (digital event streams) |
| **VNA** (network analyzer) | S-parameter matrices (complex float) | Multi-channel correlated capture |
| **Probe station** (Cascade/FormFactor) | I-V curves, C-V sweeps | Parameterized sweep data |
| **Power supply/SMU** (Keithley) | Voltage/current/time series | Duty accounting (power budget) |
| **Thermal camera** (FLIR) | 2D thermal map (float32 per pixel) | Array ingest (spatial sensor grid) |
| **SEM/microscope** | High-res images | Feature extraction (geometry verification) |
| **Pick-and-place / wire bonder** | Position + force telemetry | Safety kernel (actuator constraints) |
| **Reflow oven** | Temperature profile over time | RC core (temporal process tracking) |
| **Environmental chamber** | Temp, humidity, vibration | Safety supervisor (environmental limits) |

The key insight: **the `stream_router` does not care what the data means**.
It routes 64-bit AXI-Stream beats with priority arbitration and frame-atomic
forwarding. An oscilloscope waveform and an ADC sample window are both just
timestamped arrays of numbers. The existing `ad7124_reader` state machine
(IDLE -> HDR0 -> HDR1 -> WAIT_DRDY -> SEND_SAMPLE) generalizes to any
instrument that produces framed data with a ready signal.

### 10.3 The Instrumented Lab Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    INSTRUMENT LAYER                              │
│                                                                  │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │
│  │ Oscillo │ │ Spectrum│ │ Logic   │ │ VNA     │ │ Thermal │ │
│  │ scope   │ │ Analyzer│ │ Analyzer│ │         │ │ Camera  │ │
│  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘ │
│       │           │           │           │           │       │
│       v           v           v           v           v       │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │   Instrument Bridge Layer (extends TWAIFPGABridge)       │ │
│  │                                                          │ │
│  │   SCPI/LXI/VISA/USB → Framed AXI-Stream conversion      │ │
│  │   Each instrument = one ingest channel                   │ │
│  │   Timestamp correlation via PTP/PPS (already in hub_top) │ │
│  │   Q format conversion per instrument type                │ │
│  └──────────────────────────────────────────────────────────┘ │
└──────────┬────────────────────────────────────────────────────┘
           │
           v
┌─────────────────────────────────────────────────────────────────┐
│              REASONING FABRIC (FPGA / ASIC)                     │
│                                                                  │
│  N instrument lanes + M agent reasoning lanes                   │
│  All sharing the same stream_router, safety, provenance         │
│                                                                  │
│  Per-instrument feature extraction:                              │
│    Oscilloscope → rise/fall time, overshoot, jitter, eye diagram│
│    Spectrum     → harmonic content, spurious, phase noise       │
│    Logic        → protocol decode, timing margin, glitch detect │
│    VNA          → impedance match, return loss, group delay     │
│    Thermal      → hotspot detection, gradient analysis          │
│    Power        → dynamic current, leakage, switching energy    │
│                                                                  │
│  Cross-instrument correlation (the killer feature):             │
│    "When clock jitter exceeds 50ps on the scope, does the       │
│     VNA show impedance mismatch on the same net?"               │
│    "Does the thermal hotspot correlate with the power supply    │
│     transient captured 2ms earlier?"                            │
│    "The logic analyzer shows setup time violations on exactly   │
│     the nets where the probe station measured highest leakage." │
└──────────┬────────────────────────────────────────────────────┘
           │
           v
┌─────────────────────────────────────────────────────────────────┐
│              AGENT REASONING LAYER                               │
│                                                                  │
│  Design Agent: "The timing violation on net CLK_DIV is caused   │
│    by the 1.2nH via inductance I can see in the VNA S21 trace.  │
│    Recommending via fanout reduction from 4 to 2."              │
│                                                                  │
│  Fab Agent: "Reflow profile peak was 3°C above target for 8     │
│    seconds. Cross-referencing with probe station data shows      │
│    0.2% yield drop on the affected batch. Adjusting profile."   │
│                                                                  │
│  Test Agent: "Eye diagram margin at 2.5 Gbps is 15% below spec │
│    on Channel B. Spectrum analyzer shows 3rd harmonic at -28dBc │
│    instead of target -35dBc. Root cause: insufficient decoupling│
│    on VDD_IO rail (power analyzer confirms 80mV ripple)."       │
│                                                                  │
│  Safety Agent: "Probe station force sensor reading 2.3N exceeds │
│    the 2.0N limit for this die thickness. HOLD issued.          │
│    (safety_kernel CBF projection applied)"                      │
└──────────┬────────────────────────────────────────────────────┘
           │
           v
┌─────────────────────────────────────────────────────────────────┐
│              DESIGN ITERATION LOOP                               │
│                                                                  │
│  Measurement results → Agent analysis → Design change           │
│    → New RTL/layout → Synthesis/P&R → Fab/Program               │
│    → New measurements → ...                                     │
│                                                                  │
│  Every iteration is recorded in the HMAC-signed audit ledger.   │
│  Every design decision has full measurement provenance.         │
│  The NATS subject hierarchy provides replay of any session.     │
└─────────────────────────────────────────────────────────────────┘
```

### 10.4 What This Buys You

**1. Cross-Instrument Temporal Correlation.**

The existing `timestamp_counter` in `hub_top.v` provides PTP/PPS-locked
64-bit seconds + 32-bit ticks at 100 MHz resolution. When every instrument
stream carries the same timebase, agents can correlate across instruments
at the nanosecond level. "What was the power supply doing at the exact moment
the logic analyzer captured that glitch?" becomes a database query, not a
manual investigation.

The existing NATS JetStream persistence (24-168 hour retention per stream)
means the full multi-instrument session is replayable. The `query.py`
telemetry tool already supports search by timestamp, subject, and rule --
extending it to instrument type is trivial.

**2. Automated Characterization Loops.**

The hive monitoring pipeline already implements an automated sense-decide-act
loop: sensor window -> DSP features -> RC/Bicky classification -> OPA policy
-> actuation. The same loop applied to lab instruments becomes automated
test and characterization:

```
Instrument capture → Feature extraction → Pass/fail classification
    → Policy gate (is the measurement valid? is the DUT safe?)
    → Next measurement (adjust stimulus, move probe, change frequency)
    → Record to audit ledger with full provenance
```

The `array_ingest` module's window gating (start, duration, busy/done)
maps directly to instrument acquisition control. The `actuation_scheduler`
maps to instrument stimulus sequencing. The `safety_supervisor` watchdog
prevents runaway test sequences that could damage expensive DUTs.

**3. The Self-Characterizing SoC.**

This is where it becomes recursive: the ASIC produced by the reasoning fabric
(Section 4) is itself characterized by instruments feeding the same reasoning
fabric. The chip being tested and the chip doing the testing share the same
architecture. Specifically:

```
Generation N chip:
  - Designed by agents running on Generation N-1 reasoning fabric
  - Fabricated and assembled with instrumented equipment
  - Characterized by instruments streaming into the reasoning fabric
  - Characterization data used by agents to design Generation N+1

The measurement infrastructure IS the design infrastructure.
The test equipment feeds the same pipeline as the design tools.
Every measurement is a training sample for the next design.
```

**4. Lab Safety as a First-Class Concern.**

The TWAI safety architecture is not bolted on -- it is Ring 0 hardware. In a
lab context:

| TWAI Safety Feature | Lab Application |
|--------------------|--------------------------------------------|
| `safety_supervisor` (kill latch) | Emergency stop for probe station, laser, high-voltage |
| `safety_kernel` (CBF solver) | Force limits on probing, voltage limits on DUT |
| `duty_count` (duty limiter) | Laser exposure time limits, thermal cycling budget |
| `watchdog` (8.4ms timeout) | Instrument communication watchdog (detect hung GPIB) |
| OPA policy gate | Automated test sequence authorization |
| HMAC audit ledger | Traceability for ISO/IEC 17025 lab accreditation |
| `crypto_signer` | Signed measurement records for regulatory compliance |

The CBF solver in `safety_kernel.sv` already implements constrained
optimization for velocity/geofence. In a probe station context, the same
solver constrains probe tip force, approach velocity, and spatial bounds.
The exact same Verilog module, the exact same safety guarantee, applied to
a completely different physical domain -- exactly as `docs/WHAT_THIS_IS.md`
promises.

### 10.5 Instrument Bridge Implementation

The instrument bridge extends the existing `TWAIFPGABridge` pattern. Where
`TWAIFPGABridge` parses UART ADC frames from the Zybo, an instrument bridge
parses SCPI responses from lab equipment:

```
// Instrument types (extends hub_config.svh stream types)
localparam [7:0] STREAM_TYPE_OSCOPE    = 8'h10;  // Oscilloscope waveform
localparam [7:0] STREAM_TYPE_SPECTRUM  = 8'h11;  // Spectrum analyzer trace
localparam [7:0] STREAM_TYPE_LOGIC    = 8'h12;  // Logic analyzer capture
localparam [7:0] STREAM_TYPE_VNA      = 8'h13;  // VNA S-parameters
localparam [7:0] STREAM_TYPE_THERMAL  = 8'h14;  // Thermal image frame
localparam [7:0] STREAM_TYPE_POWER    = 8'h15;  // Power/SMU measurement
localparam [7:0] STREAM_TYPE_PROBE    = 8'h16;  // Probe station telemetry
localparam [7:0] STREAM_TYPE_ENVIRON  = 8'h17;  // Environmental chamber
```

Each instrument type gets a NATS subject:

```
twai.lab.oscope.<id>.v1        -- Oscilloscope waveforms
twai.lab.spectrum.<id>.v1      -- Spectrum analyzer traces
twai.lab.logic.<id>.v1         -- Logic analyzer captures
twai.lab.vna.<id>.v1           -- VNA S-parameter sweeps
twai.lab.thermal.<id>.v1       -- Thermal camera frames
twai.lab.power.<id>.v1         -- Power supply telemetry
twai.lab.probe.<id>.v1         -- Probe station position/force
twai.lab.environ.<id>.v1       -- Environmental chamber state
twai.lab.safety.v1             -- Lab-wide safety events
twai.lab.session.v1            -- Session metadata (operator, DUT, test plan)
```

The existing `hive_feature_adapter.py` pattern (sensor class dispatch to
domain-specific DSP) extends naturally:

```python
class LabFeatureAdapter(FeatureAdapter):
    """Route lab instrument data to domain-specific feature extractors."""

    def extract(self, window):
        if window.instrument_class == "OSCILLOSCOPE":
            return self.oscope_dsp.extract(window)  # rise/fall/jitter/eye
        elif window.instrument_class == "SPECTRUM_ANALYZER":
            return self.spectrum_dsp.extract(window)  # harmonics/spurs/noise
        elif window.instrument_class == "VNA":
            return self.vna_dsp.extract(window)  # impedance/match/delay
        elif window.instrument_class == "THERMAL":
            return self.thermal_dsp.extract(window)  # hotspot/gradient
        # ... same dispatch pattern as HiveFeatureAdapter
```

### 10.6 From Lab to Fab: The Full Manufacturing Loop

The instrumented lab concept extends beyond characterization into the
fabrication process itself. Modern PCB assembly and chip packaging involve
controllable equipment with sensor feedback:

| Fab Process Step | Equipment | Streams | Safety Constraints |
|-----------------|-----------|---------|-------------------|
| PCB reflow | Reflow oven | Temperature profile, conveyor speed | Peak temp, time-above-liquidus |
| Pick-and-place | SMT machine | Component position, force, vacuum | Placement accuracy, force limits |
| Wire bonding | Wire bonder | Bond force, ultrasonic power, position | Pull test threshold, loop height |
| Die attach | Die bonder | Epoxy volume, cure temp, alignment | Void percentage, die tilt |
| Wafer probing | Probe station | Contact resistance, I-V curves, force | Probe force, overdrive distance |
| Visual inspection | AOI/SEM | Image capture, defect detection | Alignment tolerance, solder quality |
| Functional test | ATE | Digital vectors, analog measurements | Parametric limits, binning |

Each of these is a sensor-actuator loop -- exactly what TWAI is built for.
The `actuation_scheduler` in `hub_top.v` already manages windowed actuation
with safety gating. A reflow oven's temperature profile is a scheduling
problem; a wire bonder's bond sequence is a tile command sequence.

The OPA policy engine already handles ABORT/HOLD/ADVANCE cascades. In a fab
context:

```rego
# Example: Wire bond safety policy (extends hive.rego pattern)
abort_wirebond {
    input.bond_force_grams > 80            # Excessive force
}
abort_wirebond {
    input.loop_height_um < 50              # Wire too close to die
}
hold_wirebond {
    input.pull_test_grams < 5              # Weak bond detected
}
hold_wirebond {
    input.substrate_temp_c > 175           # Thermal budget exceeded
}
```

### 10.7 Data Rates and Scaling

Lab instruments produce substantially more data than beehive sensors:

| Source | Sample Rate | Data Rate | Streams |
|--------|------------|-----------|---------|
| Hive ADC (current) | 50 SPS/ch x 2 ch | ~200 B/s | 2 |
| Oscilloscope (1 GS/s, 8-bit) | 1 GHz | ~1 GB/s (burst) | 1-4 ch |
| Spectrum analyzer (sweep) | ~1 kHz update | ~100 KB/s | 1 |
| Logic analyzer (500 MHz) | 500 MHz | ~500 MB/s (burst) | 8-32 ch |
| VNA (sweep) | ~10 Hz sweep | ~10 KB/s | 2-4 port |
| Thermal camera (30 fps) | 30 Hz x 640x480 | ~36 MB/s | 1 |
| Probe station I-V | ~1 kHz | ~10 KB/s | 2-4 ch |
| ATE (mixed signal) | Variable | ~100 MB/s | 64-256 ch |

The current TWAI fabric handles ~200 B/s on 64-bit AXI-Stream at 100 MHz
(theoretical max: 800 MB/s). A single scope channel at full rate saturates
the bus. This means the scaled fabric (Section 3) needs:

1. **Per-instrument local processing.** Extract features on-instrument or at
   the bridge, not in the central fabric. The oscilloscope doesn't stream raw
   samples -- it streams extracted features (rise time, jitter, eye metrics).
   This is the same pattern as the hive DSP: raw audio -> 13-dim features.

2. **Hierarchical routing.** Instrument clusters feed local fabric nodes;
   local nodes feed the central reasoning fabric. The existing `stream_router`
   with parameterized `NUM_INPUTS` composes into a tree.

3. **Burst capture with windowing.** The `array_ingest` pattern (gate_active
   for duration_ticks) already handles burst capture. An oscilloscope
   single-shot acquisition is exactly this: trigger, capture window,
   process, done.

### 10.8 Existing TWAI Components That Transfer Directly

| TWAI Component | Lab/Fab Application | Changes Needed |
|---------------|---------------------|----------------|
| `ad7124_reader.sv` | Instrument data ingest (framed captures) | Generalize SPI to SCPI/LXI/USB |
| `array_ingest.sv` | Burst acquisition control | None (already parameterized) |
| `stream_router.sv` | Multi-instrument arbitration | Scale NUM_INPUTS |
| `hub_stream_fabric.sv` | Instrument priority routing | Add more slots |
| `dsp_feature_edge.v` | Per-instrument feature extraction | New feature sets per instrument |
| `rc_core.sv` | Temporal process tracking (reflow profiles, aging) | Retrain weights |
| `bicky_inference.sv` | Pass/fail classification, fault detection | Retrain for lab classes |
| `safety_supervisor.v` | Lab emergency stop, equipment watchdog | Wire to lab interlock bus |
| `safety_kernel.sv` + CBF | Probe force limits, thermal budgets | New constraint parameters |
| `crypto_signer.sv` | Signed measurement records (ISO 17025) | Production-grade crypto IP |
| `timestamp_counter` | Cross-instrument time correlation | Already PTP/PPS locked |
| NATS JetStream | Instrument data bus + replay | Add lab subjects |
| OPA/Rego policy | Test sequence authorization, safety rules | New domain rules |
| HMAC audit ledger | Measurement provenance, regulatory compliance | Already production |
| `twai-evolve` | Optimize test sequences, characterization plans | New fitness functions |
| Flash-MoE reasoning | Analyze correlated measurements, root-cause | New system prompts |

The remarkable thing is that the "Changes Needed" column is mostly "retrain
weights" or "add parameters" rather than "redesign". The architecture was
designed to be domain-agnostic (`docs/WHAT_THIS_IS.md`), and lab
instrumentation is just another domain.

### 10.9 The Complete Vision

```
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│   DESIGN                 FAB                  TEST            │
│   ┌─────────┐           ┌─────────┐          ┌─────────┐    │
│   │ Agents  │           │ Agents  │          │ Agents  │    │
│   │ generate│──────────>│ control │─────────>│ analyze │    │
│   │ RTL     │           │ fab     │          │ results │    │
│   └────┬────┘           └────┬────┘          └────┬────┘    │
│        │                     │                    │          │
│        │    ┌────────────────┼────────────────────┘          │
│        │    │                │                               │
│        v    v                v                               │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              REASONING FABRIC                        │   │
│   │                                                      │   │
│   │  Design streams:  RTL, constraints, floorplan, sim   │   │
│   │  Fab streams:     pick-place, reflow, bond, cure     │   │
│   │  Test streams:    scope, VNA, logic, thermal, ATE    │   │
│   │  Agent streams:   reasoning chains, tool outputs     │   │
│   │                                                      │   │
│   │  All sharing: safety gates, audit ledger, timebase   │   │
│   └──────────────────────┬──────────────────────────────┘   │
│                          │                                   │
│                          v                                   │
│   ┌──────────────────────────────────────────────────────┐  │
│   │              KNOWLEDGE BASE                           │  │
│   │                                                       │  │
│   │  Every design decision linked to its measurements     │  │
│   │  Every measurement linked to its design context       │  │
│   │  Every fab step linked to its yield impact            │  │
│   │  Every test result linked to its root cause           │  │
│   │                                                       │  │
│   │  Queryable by: time, instrument, design revision,     │  │
│   │  component, net, process step, operator, DUT          │  │
│   │                                                       │  │
│   │  HMAC-signed, replayable, ISO 17025 compliant         │  │
│   └──────────────────────┬───────────────────────────────┘  │
│                          │                                   │
│                          v                                   │
│   ┌──────────────────────────────────────────────────────┐  │
│   │              NEXT GENERATION                          │  │
│   │                                                       │  │
│   │  Agents use the full design-fab-test knowledge base   │  │
│   │  to design the next generation chip.                  │  │
│   │                                                       │  │
│   │  "The 3rd harmonic issue on Gen 1 was caused by via   │  │
│   │   inductance (VNA trace #4721, timestamp 2026-04-15   │  │
│   │   14:23:07.123456789). Gen 2 uses coaxial vias on     │  │
│   │   all high-speed nets."                               │  │
│   │                                                       │  │
│   │  Every design choice has empirical justification.     │  │
│   │  No knowledge is lost between generations.            │  │
│   └──────────────────────────────────────────────────────┘  │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

The TWAI platform is not just a beehive monitor that could theoretically
generalize. It is a **measurement-driven closed-loop control system** that
happens to be pointed at beehives first. Pointing it at a chip design lab
requires new feature extractors and new policy rules, but the core
architecture -- streaming ingest, parallel processing, safety gating,
signed provenance, and agent-driven reasoning -- transfers intact.

The NATS subject hierarchy, the OPA policy cascade, the HMAC audit ledger,
the AXI-Stream fabric, the RC temporal memory, and the Bicky classifier
are all domain-agnostic primitives. A beehive and a semiconductor fab are
both multi-sensor environments with safety constraints and temporal
correlations. The TWAI architecture treats them identically.

---

## Appendix A: Glossary

| Term | Definition |
|------|-----------|
| **Lane** | One parallel processing pipeline in the reasoning fabric (RC + Bicky + safety) |
| **Reasoning fabric** | The full FPGA/ASIC array of lanes + routing + safety |
| **Embedding projector** | Hardware matrix-vector multiply for dimensionality reduction |
| **Agent stream** | The sequence of state vectors an agent produces during reasoning |
| **Crossbar** | N:N switch fabric connecting all lanes for inter-agent communication |
| **CBF** | Control Barrier Function -- constraint projection for safety |
| **RC** | Reservoir Computing -- dynamical system used as compressed temporal memory |
| **Bicky** | Constructive feedforward neural network for fast classification |
| **Flash-MoE** | Mixture-of-Experts LLM (Qwen3.5-397B) with NVMe expert paging |
| **ANE** | Apple Neural Engine -- used for Tier 1/2 fast inference in Lex kernel |

## Appendix B: File Cross-References

| Concept | Source File |
|---------|------------|
| Hub top-level integration | `platform/fpga/hub-zybo/fpga/src/hub_top.v` |
| Reservoir computing core | `platform/fpga/hub-zybo/fpga/src/blocks/rc/rc_core.sv` |
| Bicky feedforward inference | `platform/fpga/hub-zybo/fpga/src/blocks/neural/bicky_inference.sv` |
| N:1 stream router | `platform/fpga/hub-zybo/fpga/src/common/ip/stream_router.sv` |
| Safety supervisor (Ring 0) | `platform/fpga/hub-zybo/fpga/src/blocks/safety_supervisor.v` |
| Safety kernel + CBF solver | `platform/fpga/hub-zybo/fpga/src/blocks/safety_kernel.sv` |
| CBF constrained optimization | `platform/fpga/hub-zybo/fpga/src/blocks/cbf_solver.sv` |
| ADC streaming ingest | `platform/fpga/hub-zybo/fpga/src/blocks/ad7124_reader.sv` |
| Window gating | `platform/fpga/hub-zybo/fpga/src/blocks/array_ingest.sv` |
| Stream data fabric | `platform/fpga/hub-zybo/fpga/src/blocks/hub_stream_fabric.sv` |
| RC/Bicky mode switching | `platform/fpga/hub-zybo/fpga/src/blocks/hub_rc_mode_fabric.sv` |
| Deployment constants | `platform/fpga/hub-zybo/fpga/src/hub_config.svh` |
| DSP feature extraction | `rtl/dsp_feature_edge/dsp_feature_edge.v` |
| Cryptographic signing | `platform/fpga/hub-zybo/fpga/src/blocks/crypto_signer.sv` |
| Flash-MoE library | `lex/orchestrator/flash_moe_lib.h`, `flash_moe_lib.m` |
| Lex orchestrator | `lex/orchestrator/TWAIOrchestrator.m` |
| ANE inference | `lex/orchestrator/TWAIANEInference.m` |
| OPA policy evaluator | `lex/orchestrator/TWAIOPAEvaluator.m` |
| Audit ledger | `lex/orchestrator/TWAIAuditLedger.m` |
| FPGA bridge | `lex/orchestrator/TWAIFPGABridge.m` |
| Hyperagent optimizer | `lex/hyperagent/twai_evolve.py` |
| System architecture | `ARCHITECTURE.md` |
| Platform vision | `docs/WHAT_THIS_IS.md` |
