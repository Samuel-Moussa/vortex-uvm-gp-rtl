# SVA and the sequence architecture — interview reference

*Read from the live source at `Vortex/sim/uvmsim/`, not from memory. Every count and line
reference below was measured.*

---

# PART 1 — The assertions (SVA)

## 1.1 Inventory — measured, not estimated

| Interface file | `assert property` | `cover property` |
|---|---:|---:|
| `tb/vortex_axi_if.sv` | **30** | **16** |
| `tb/vortex_mem_if.sv` | 4 | 0 |
| `tb/vortex_dcr_if.sv` | 3 | 0 |
| `tb/vortex_if.sv` | 2 | 0 |
| `tb/vortex_status_if.sv` | 1 | 0 |
| **Total** | **40** | **16** |

> ⚠ **The papers understate this.** They say "~15–18 protocol properties plus 11 handshake-stability
> assertions." The real figure is **40 concurrent assertions and 16 cover properties**. Quote 40/16.

## 1.2 The five assertion classes on AXI

**(a) Handshake stability** — VALID and payload must not change before READY.

```systemverilog
property aw_valid_stable_p;
    @(posedge clk) disable iff (!reset_n)
    (awvalid && !awready) |=> awvalid;
endproperty

property aw_addr_stable_p;
    @(posedge clk) disable iff (!reset_n)
    (awvalid && !awready) |=> $stable(awaddr);
endproperty

assert_aw_valid_stable: assert property (aw_valid_stable_p)
    else $error("[VORTEX_AXI_IF] AWVALID dropped before AWREADY handshake!");
```

Applied across AW/W/B/AR/R for VALID, address, data, and ID — that is the bulk of the 30.

**Syntax to be able to explain out loud:**
- `@(posedge clk)` — the sampling clock for the property.
- `disable iff (!reset_n)` — the assertion is vacuously true during reset; without it every
  assertion fires at time 0.
- `|=>` — *non-overlapping* implication: the consequent is checked on the **next** clock. This is
  the right operator for stability ("if I am stalled now, I must still be valid next cycle").
- `|->` — *overlapping* implication: consequent checked in the **same** cycle. Used where the
  property is about the same beat, e.g. `wlast`.
- `$stable(sig)` — the signal has the same value as the previous sampled cycle.
- `$rose(sig)` — 0→1 this cycle.

**(b) Same-beat legality** — `|->`, because it constrains the current transfer:

```systemverilog
property wlast_asserted_on_write_p;
    @(posedge clk) disable iff (!reset_n)
    (wvalid && wready) |-> wlast;      // single-beat writes in this environment
endproperty
```

**(c) Burst legality** — `aw_burst_legal`, `ar_burst_legal`, `aw_size_legal`, `ar_size_legal`,
`aw_wrap_len_legal`, `ar_wrap_len_legal`, and **4 KB boundary** checks
(`aw_4k_boundary`, `ar_4k_boundary`) — the AXI rule that a burst may not cross a 4 KB page.

**(d) Outstanding-transaction tracking — assertions with auxiliary state.** This is the class
worth showing an interviewer, because it is more than a one-line property: a counter in the
interface tracks completed-but-unacknowledged writes, and the assertion references it.

```systemverilog
int unsigned completed_writes_outstanding;

always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) completed_writes_outstanding <= '0;
    else begin
        automatic int signed next_completed = int'(completed_writes_outstanding);
        if (wvalid && wready && wlast) next_completed++;   // a write completed
        if (bvalid && bready)          next_completed--;   // its response returned
        if (next_completed < 0) next_completed = 0;        // clamp
        completed_writes_outstanding <= int'(next_completed);
    end
end

property bvalid_after_wlast_p;
    @(posedge clk) disable iff (!reset_n)
    $rose(bvalid) |-> (completed_writes_outstanding > 0 || (wvalid && wready && wlast));
endproperty
```

**What this catches:** a write response for a write that never happened. Same pattern for
`rvalid_has_outstanding_ar` on the read side, and `rlast_on_last_beat` / `rlast_not_early` use a
`r_beat_count` register to check RLAST lands exactly on beat `arlen+1`.

**(e) Reset-window properties** — `valids_low_during_reset`, `valids_low_after_reset`.

## 1.3 The 16 cover properties

`cover property` records that an interesting *legal* scenario actually occurred — it is coverage,
not checking. Example: `cover_w_before_aw` records the W-channel beat arriving ahead of its
address phase, a legal AXI ordering the DUT might never produce. These feed the **Directive**
coverage category, which is at **100%** in both banks.

## 1.4 Assertions elsewhere in the environment

Not every check is a concurrent property. Also present:

- **Elaboration-time asserts** — a topology mismatch between plusargs and the compiled RTL calls
  `$fatal` at time 0 with a named diagnostic, rather than simulating the wrong design.
- **`initial assert ($bits(uuid) > 1)`** in the commit probe — catches a degenerate build where
  the uuid width collapses and the lockstep key silently becomes useless.
- **DUT-side RTL assertions** are gated into the verdict: any RTL assertion firing fails the run
  with a distinct exit code, and failing runs are excluded from coverage merging.

---

# PART 2 — The sequence architecture

## 2.1 The class hierarchy as it actually exists

```
uvm_sequence
├── vortex_base_sequence          ← single-agent base   (uvm_env/sequences/)
├── vortex_virtual_sequence       ← multi-agent base, `uvm_declare_p_sequencer
│   ├── kernel_launch_vseq
│   ├── host_coverage_vseq
│   ├── random_instr_stress_vseq
│   └── vortex_functional_mem_vseq
│
└── uvm_sequence #(<agent transaction>)   ← per-agent bases
    ├── host_base_sequence  → reset / load_program / configure_dcr /
    │                          launch_kernel / wait_done / read_result / complete_test
    ├── dcr_base_sequence   → startup_config / perf_config / random
    ├── axi_base_sequence   → single_write / single_read / write_read /
    │                          burst_write / burst_read / random / stress
    └── mem_base_sequence   → write / read / write_read / block_write /
                               block_read / random
```

## 2.2 `vortex_base_sequence` vs `vortex_virtual_sequence` — the real difference

**The difference is which sequencer the sequence talks to, and therefore how it reaches one.**

| | `vortex_base_sequence` | `vortex_virtual_sequence` |
|---|---|---|
| Runs on | **One** agent sequencer | The **virtual** sequencer |
| Started with | `seq.start(env.m_mem_agent.m_sequencer)` | `vseq.start(env.m_virtual_sequencer)` |
| Sequencer handle | `m_sequencer` (untyped, set by `start()`) | `p_sequencer` (**typed**, via `` `uvm_declare_p_sequencer ``) |
| Generates items? | **Yes** — `start_item`/`finish_item` | **No** — it starts *other* sequences |
| Purpose | Drive one protocol | **Coordinate across agents** |

**The mechanism that makes a virtual sequence work is one macro:**

```systemverilog
class vortex_virtual_sequence extends uvm_sequence;
    `uvm_declare_p_sequencer(vortex_virtual_sequencer)
    ...
endclass
```

`` `uvm_declare_p_sequencer(T) `` declares a handle `p_sequencer` of type `T` and, in
`pre_body`, `$cast`s `m_sequencer` into it. Without it you only have `m_sequencer`, typed as the
generic `uvm_sequencer_base`, from which you cannot reach `m_host_sequencer` etc. **That macro is
the entire reason a virtual sequence can address multiple agents.**

The virtual sequencer itself generates no transactions — it is only a container of handles:

```systemverilog
class vortex_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(vortex_virtual_sequencer)

    mem_sequencer  m_mem_sequencer;
    axi_sequencer  m_axi_sequencer;
    dcr_sequencer  m_dcr_sequencer;
    host_sequencer m_host_sequencer;

    vortex_config cfg;
endclass
```

The env assigns those handles in `connect_phase`. `end_of_elaboration_phase` then prints a
connection table and **warns if a handle is null while its agent is configured ACTIVE** — so a
mis-wired sequencer is reported at elaboration instead of becoming a null-pointer crash mid-run.

## 2.3 How a virtual sequence drives many sequences — the real code

```systemverilog
class kernel_launch_vseq extends vortex_virtual_sequence;
    `uvm_object_utils(kernel_launch_vseq)

    virtual task body();
        host_launch_kernel_sequence launch_seq;
        host_wait_done_sequence     wait_seq;

        if (p_sequencer == null)
            `uvm_fatal("K_L_VSEQ", "p_sequencer is null — start this sequence on env.m_virtual_sequencer")

        launch_seq = host_launch_kernel_sequence::type_id::create("launch_seq");
        if (cfg != null) begin
            launch_seq.startup_address = cfg.startup_addr;
            launch_seq.num_clusters    = cfg.num_clusters;
            launch_seq.num_cores       = cfg.num_cores;
            launch_seq.num_warps       = cfg.num_warps;
            launch_seq.num_threads     = cfg.num_threads;
        end
        launch_seq.start(p_sequencer.m_host_sequencer);   // ← sub-sequence on a real sequencer

        wait_seq = host_wait_done_sequence::type_id::create("wait_seq");
        if (cfg != null) wait_seq.timeout_cycles = int'(cfg.test_timeout_cycles);
        wait_seq.start(p_sequencer.m_host_sequencer);
    endtask
endclass
```

**The pattern in one sentence:** a virtual sequence's `body()` creates sub-sequences and calls
`sub_seq.start(p_sequencer.<agent>_sequencer)` on each — sequentially for ordering, or inside
`fork ... join` when two agents must be driven concurrently. The virtual sequence contributes
**ordering and configuration**; the sub-sequences contribute **transactions**.

Config propagates automatically: `vortex_virtual_sequence::pre_body()` does `cfg = p_sequencer.cfg`,
so every derived vseq has the topology parameters without a `uvm_config_db` lookup.

## 2.4 The AXI sequences specifically

`axi_base_sequence extends uvm_sequence #(axi_transaction)` with seven derived classes
(`single_write`, `single_read`, `write_read`, `burst_write`, `burst_read`, `random`, `stress`).
They are **parameterized on the transaction type**, which the two Vortex base classes are not —
because those two never produce items themselves.

---

# PART 3 — ⚠ The question you must be ready for

## 3.1 The finding: the AXI and memory sequences are never started

Measured: `axi_single_write_seq`, `axi_burst_write_seq`, `axi_stress_seq`, `axi_random_seq`,
`mem_random_sequence` and their siblings **do not appear in any test or virtual sequence.** They
are defined and compiled; nothing runs them.

**Why — and this is the architecturally correct answer, not an excuse:** the AXI agent is a
**responder**, not a stimulus generator. The driver has **no `seq_item_port.get_next_item()` call
at all.** Its `run_phase` is a set of `forever` loops watching the AW/W/AR channels and replying
on B/R out of the memory model:

```
// axi_driver.svh:5-6
// This driver acts as the memory responder for the Vortex DUT, which is an
// AXI Master. It monitors the AW/W/AR channels and responds on the B/R channels
```

and it hard-fails if the memory model is missing, because a responder with no memory would
silently answer nothing:

```systemverilog
`uvm_fatal("AXI_DRV", "Failed to get mem_model from config DB! AXI responder requires memory access.")
```

**The DUT is the master. It issues the transactions. There is nothing for an AXI sequence to
drive.** This is the role inversion — the same point as the deck's "role-inverted agents" slide,
visible concretely in the driver.

> **Be straight about this if asked.** "Those sequence classes are scaffolding from bring-up for a
> master-mode AXI agent; in the final architecture the agent is a responder, so they are not part
> of the active flow." That is a far better answer than implying they run. If you have time before
> the interview, deleting the unused ones is defensible cleanup.

## 3.2 So what *does* run?

**Four virtual sequences, all started on `env.m_virtual_sequencer`:**

| Test | Virtual sequence |
|---|---|
| `kernel_launch_test` | `kernel_launch_vseq` |
| `host_coverage_test` | `host_coverage_vseq` |
| `random_instruction_stress_test` | `random_instr_stress_vseq` |
| (base, all tests) | `dcr_startup_config_sequence` + `dcr_perf_config_sequence`, started directly on `m_dcr_sequencer` from `vortex_base_test` |

So the **only** sequence-driven traffic is: **DCR configuration, kernel launch, and completion
waiting.** That is the launch protocol — not the test content.

## 3.3 Where the scenarios actually come from

**The scenario is the program.** Stimulus is a compiled RISC-V ELF sitting in the memory model;
the DUT fetches and executes it. The UVM test controls *how* it is launched and perturbed; the
program controls *what* executes. They are orthogonal and composed at build level:

```bash
make sim TEST=kernel_launch_test PROGRAM_NAME=vecadd_lite CLUSTERS=1 CORES=1 WARPS=4 THREADS=4
```

**Two stimulus sources:**

**(a) ~30 directed kernels**, each written against a specific coverage or architectural target —
all 13 FPU operation classes; tensor-unit WMMA including multi-warp collective launches;
nested-divergence towers (asymmetric 3v1→2v1→1v1); barriers under partial thread masks;
`wspawn`/`tmc` sweeps; MSHR and memory-pressure stress; a 232 KB-text kernel for instruction-cache
pressure; a 256 KB high-entropy store stress for toggle; division corner cases; CSR writes under
SIMT masks; VOTE/SHFL.

**(b) Constrained-random via riscv-dv** — 12 seed profiles targeting rv32im, with GPU-specific
post-processing (machine-mode CSR stripping, `ecall`→`ebreak`). Two profiles are excluded as
**unimplementable on this DUT** (unaligned load/store — no misaligned support; illegal-instruction
— no trap architecture), stated rather than silently skipped.

**(c) Protocol-level perturbation, which is the closest thing to classic sequence stimulus** —
and it lives in the responder, plusarg-gated:

- `+AXI_THROTTLE` — the slave injects `ready` wait-states, creating backpressure. This is what
  exercises the handshake-stability assertions of Part 1 (moved those assertions from 84.78% to
  93%).
- `+AXI_FLOOD` — the slave streams R responses back-to-back to force DUT-side `rready`
  backpressure.

Both are **proven byte-identical when off**, so the default regression is unperturbed.

## 3.4 How to say this in one paragraph

> "Vortex is a bus master that fetches its own instructions, so there is no sequence-item stimulus
> path — randomizing AXI transactions would be randomizing the DUT's own output. The sequence
> layer therefore drives only the launch protocol: DCR configuration, kernel launch, and
> completion, coordinated by a virtual sequence over the host and DCR sequencers. The actual test
> content is the compiled program — about thirty directed kernels written against specific
> coverage targets, plus twelve riscv-dv constrained-random profiles. Protocol-corner stimulus is
> injected from the responder side instead, as plusarg-gated backpressure and flood modes, which
> is what exercises the AXI stability assertions."

---

# Quick-reference: numbers to have ready

| | |
|---|---|
| Concurrent assertions | **40** (30 AXI, 4 mem, 3 DCR, 2 vortex_if, 1 status) |
| Cover properties | **16** (all AXI) → Directive coverage **100%** both banks |
| UVM agents | 5 — host, DCR, AXI, memory, status |
| Virtual sequences | 4 |
| Agent sequence classes | 24 across 4 agents (AXI/mem ones are inactive scaffolding) |
| Directed kernels | ~30 |
| riscv-dv profiles | 12 active, 2 excluded as unimplementable |
| Assertion coverage | 96.9% (1CL) / 98.9% (2CL) |
