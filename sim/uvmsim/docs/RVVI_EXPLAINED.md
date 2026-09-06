# RVVI — the standard, and how this project uses it

*Part 2 read from live source: `tb/rvvi_if.sv`, `uvm_env/rvvi_monitor.svh`,
`uvm_env/rvvi_txn.svh`, `uvm_env/lockstep_pkg.sv`, `uvm_env/lockstep_scoreboard.svh`.*

---

# PART 1 — RVVI as a general concept

## 1.1 What it is

**RVVI = RISC-V Verification Interface.** It is an open standard that defines *how a RISC-V design
under test exposes its architectural retirement events*, so that a **reference model** can be run
in **lockstep** against it and every retired instruction compared.

Originally developed by **Imperas**, then opened up and hosted for the RISC-V community
(`github.com/riscv-verification/RVVI`). It is the interface behind **ImperasDV** and is the
comparison mechanism used by **OpenHW Group's `core-v-verif`** for the CV32E40P/CV32E40X/CVA6
cores.

## 1.2 The problem it solves

Before a standard existed, every core team wrote its own bespoke tracer and its own bespoke
comparison script. That meant:

- the reference model was welded to one DUT,
- the comparison logic was rewritten per project,
- and the *quality* of checking varied wildly and invisibly.

RVVI decouples the three parties:

```
   DUT  ──(RVVI-TRACE)──►  comparison layer  ◄──(RVVI-API)──  reference model
```

Any RVVI-compliant DUT can be checked against any RVVI-compliant model, using a comparison layer
neither of them owns.

## 1.3 The two halves of the standard

### (a) RVVI-TRACE — the DUT side (in SystemVerilog: **RVVI-VLG**)

A SystemVerilog interface the DUT drives, indexed **per hart and per issue slot**. The core
signal set:

| Signal | Meaning |
|---|---|
| `valid` | An instruction retired this cycle — **the event that triggers a comparison** |
| `order` | 64-bit **monotonically incrementing** retirement counter, per hart |
| `insn` | The retired instruction encoding |
| `pc_rdata` | PC of the retired instruction |
| `pc_wdata` | Next PC |
| `x_wdata[32]`, `x_wb` | Integer register file write data + write-enable bitmask |
| `f_wdata[32]`, `f_wb` | Floating-point register file equivalent |
| `v_wdata[]`, `v_wb` | Vector register file equivalent |
| `csr[4096]`, `csr_wb` | CSR values + which were written |
| `trap` | The instruction trapped |
| `intr` | Retirement is the first instruction of a trap handler |
| `halt`, `mode`, `ixl` | Halt state, privilege mode, XLEN mode |
| `lrsc_cancel` | Load-reserved/store-conditional reservation cancelled |

**The design philosophy: report *architectural state change*, not microarchitecture.** RVVI says
nothing about pipelines, stalls, or issue queues — only "instruction N retired, here is what it
changed."

### (b) RVVI-API — the reference-model side

A C API for driving and interrogating the model. Representative calls:

| Call | Purpose |
|---|---|
| `rvviRefInit()` | Instantiate the reference model |
| `rvviRefPcSet()` | Force the model's PC (e.g. at reset) |
| `rvviRefEventStep()` | **Step the model by one instruction** |
| `rvviDutRetire()` | Notify the model that the DUT retired — triggers the compare |
| `rvviRefNetSet()` | **Inject an asynchronous input** (interrupt, debug request) into the model |
| `rvviRefCsrCompare()`, `rvviRefGprsCompare()` | Explicit state comparisons |

## 1.4 How lockstep actually runs

```
DUT retires instruction  →  valid=1, order=N, pc_rdata, x_wb/x_wdata
                                    │
                                    ▼
                    comparison layer calls rvviRefEventStep()
                                    │
                                    ▼
              reference model executes exactly one instruction
                                    │
                                    ▼
                compare PC, GPR/FPR writeback, CSRs  →  pass / mismatch
```

The **`order` field is the alignment key** — it guarantees the comparator knows which DUT
retirement corresponds to which model step, even with multiple issue slots.

## 1.5 The hard part: asynchronous events

This is where naive lockstep breaks, and RVVI's answer is instructive.

An interrupt is not caused by the program — it arrives from outside. If the DUT takes it after
instruction 500 and the model takes it after 502, **everything diverges** even though both are
correct. RVVI's mechanism is `rvviRefNetSet()`: the comparison layer observes *when the DUT took
the interrupt* and forces the model to take it at **the same instruction boundary**.

Equivalent problem for loads from shared/volatile memory: some flows add a **"load bus"** that
feeds DUT-observed load data into the model, so the model follows the DUT on values it cannot
predict. *(This is exactly the idea this project generalises into its two-pass load-value feed.)*

## 1.6 What RVVI assumes — and why that matters here

RVVI is built for **scalar RISC-V harts**. Baked-in assumptions:

- **One architectural context per hart.** A single PC, one register file, one thread of control.
- **One retirement = one instruction = one `order` value**, strictly increasing.
- **No concept of a thread mask.** There is no signal that says "lanes 0 and 2 executed, lanes 1
  and 3 were masked off."
- **No divergence or reconvergence state.**

> **For a SIMT GPGPU, every one of those assumptions fails.** A warp has one PC but *N* lanes with
> independent data; retirement is per-warp-instruction with a mask; and a single instruction can
> produce several retirement records. That is why "just use RVVI" is not an available answer for
> Vortex — and why this project had to build the missing layer.

---

# PART 2 — How RVVI is used in this project

## 2.1 The deliberate choice: RVVI *pattern*, transaction-level

The environment follows **core-v-verif's `uvma_rvvi` architecture** — a dedicated interface, a UVM
monitor, and an analysis port — but carries **records rather than RVVI-TRACE pins**.

From `tb/rvvi_if.sv:19-22`:

> *"TRANSACTION-LEVEL by design (records, not RVVI-TRACE pins): the record struct carries widened
> scalars + a dynamic `data[]`, so the interface needs NO parameters — one `virtual rvvi_if` type
> is valid for ANY NUM_CLUSTERS/NUM_CORES/NUM_WARPS/NUM_THREADS/SIMD_WIDTH/ISSUE_WIDTH."*

**Why this is the right call, and how to defend it:** a signal-level RVVI interface must be
parameterized on lane count and XLEN. In SystemVerilog, `virtual rvvi_if #(4)` and
`virtual rvvi_if #(8)` are **different, incompatible types** — so a single monitor could not hold
handles to both, and the environment would stop being config-generic. Widened scalars plus a
dynamic `data[]` array make **one** interface type serve every topology.

The file also records what a future upgrade would need (`:23-26`): a signal-level RVVI-TRACE
version would add `clocking mon_cb @(posedge clk); default input #1step;` and sample pins through
it. With record hand-off there is no cross-domain signal sampling, so no clocking block is needed.

## 2.2 The data path

```
vx_commit_probe   (bind VX_commit)      ┐
vx_lsu_probe      (bind VX_lsu_slice)   ┘
        │  each instantiates ONE rvvi_if and push()es records into it,
        │  and self-registers that instance in rvvi_registry_pkg at time 0
        ▼
   rvvi_if           ← persistent queue of dut_retire_s
        │
        ▼
   rvvi_monitor      ← discovers every registered vif after #1,
        │              drains on @(posedge vif.clk),
        │              publishes rvvi_txn on uvm_analysis_port
        ▼
 lockstep_scoreboard ← uvm_analysis_imp, routes by rec.kind
```

**The registry pattern is what makes this scale.** Probes are `bind`-instantiated, so the
testbench cannot know how many exist — that depends on `NUM_CLUSTERS × NUM_SOCKETS × SOCKET_SIZE`.
Each probe registers itself at time 0; the monitor snapshots the list after `#1`, when all time-0
registrations are guaranteed complete:

```systemverilog
package rvvi_registry_pkg;
    virtual rvvi_if vifs[$];
    function automatic void rvvi_register(virtual rvvi_if v);
        vifs.push_back(v);
    endfunction
endpackage
```

**No path enumeration, no per-config edit** — the same principle as the `bind` itself.

## 2.3 Two engineering details worth knowing

**(a) The queue is persistent, so nothing is ever dropped.** If the monitor's drain thread loses
the scheduling race on an edge — or is killed when `run_phase` ends — the records simply wait.
A final `extract_phase` sweep collects the remainder:

```systemverilog
function void extract_phase(uvm_phase phase);
    super.extract_phase(phase);
    foreach (m_vifs[i]) drain(m_vifs[i]);
endfunction
```

This is correct because **UVM runs all `extract_phase`s before any `check_phase`**, so the
scoreboard always sees the complete stream before rendering a verdict. (`ap.write()` from a
function phase is legal — `write` is a function.)

**(b) The channel is inert by default.** `lockstep_pkg::lockstep_en` is set from `+LOCKSTEP` by
the probe at time 0, default 0. With the gate off, runs are proven byte-identical to the plain
environment — the observability layer cannot perturb what it observes.

## 2.4 The record, mapped against real RVVI

`dut_retire_s` (`lockstep_pkg.sv:41-56`):

| Field | RVVI equivalent | Note |
|---|---|---|
| `uuid` | ≈ `order` | **Richer than RVVI's.** Also encodes `(core, warp)` in its top 12 bits |
| `pc` | `pc_rdata` | Full byte PC — `to_fullPC()` applied at push |
| `rd` | index into `x_wb` | Destination register |
| `data[]` | ≈ `x_wdata` | **Per-SIMT-lane**, dynamically sized — RVVI has one scalar value |
| `wb` | `x_wb` | Writeback valid; capture is gated on it |
| `tmask` | **none** | ⭐ SIMT-only: which lanes are active |
| `sid` | **none** | ⭐ SIMT-only: SIMD-group index, lane base = `sid*SIMD_WIDTH` |
| `wid` | **none** | ⭐ SIMT-only: warp id |
| `kind` | **none** | ⭐ `KIND_COMMIT` / `KIND_LOAD` — routing key |
| `sop`/`eop` | **none** | Multi-beat framing |
| `cid` | — | Core id (superseded — the scoreboard derives it from `uuid`) |

**The four ⭐ fields are precisely the SIMT extension RVVI does not have** — and they are what
Rules 1–4 of the alignment methodology operate on.

**`kind` deserves its own note.** Real RVVI has one retirement channel. This environment needs
two, because **load data never reaches the commit arbiter** (finding R8) — so the LSU probe
supplies a second stream, and the scoreboard routes on `rec.kind`. That is a *design consequence
of the DUT's observability*, not a stylistic choice.

## 2.5 What is deliberately absent

Compared with full RVVI-TRACE, this implementation does not carry `insn`, `pc_wdata`, `csr[]`,
`f_wdata`, `v_wdata`, `lrsc_cancel`, `trap`, `intr`, `halt`, `mode`, or `ixl`.

Most of that is **not applicable rather than unfinished**:

- `trap` / `intr` / `mode` — **Vortex has no trap architecture and no privilege modes.** There is
  nothing to report.
- `csr[]` — performance-counter CSRs are model-divergent by definition (alignment Rule 5); the
  architectural ones are covered by the end-state compare.
- `v_wdata` — no vector extension in this configuration.

The honest gap is **`insn`**: carrying the instruction word would let the comparator report *what*
diverged, not just *that* a value differed. Today the disassembly comes from the reference model.

## 2.6 The scope limit to state out loud

**This lockstep is writeback-domain only** (OBS-022). Capture is gated on
`commit_arb_if[i].data.wb`, so instructions with no architectural result — `nop`, `beq`,
`jalr x0` — never enter the stream. Consequences:

- a wrong branch is caught only **indirectly**, via the successor's PC;
- **stores are outside lockstep entirely** — the end-state scoreboard covers them.

This is exactly how Spike's 11,487 retirements reconcile to the flow's 11,076 compared writebacks.
Quoting the reconciliation rather than the larger number is the honest form.

---

# One-paragraph answer for the interview

> "RVVI is the RISC-V Verification Interface — an open standard from Imperas, used by OpenHW's
> core-v-verif, that defines how a DUT exposes retirement events so a reference model can be run
> in lockstep against it. It has two halves: RVVI-TRACE, the SystemVerilog signal set the DUT
> drives — `valid`, `order`, `pc_rdata`, `x_wdata`/`x_wb`, CSRs, trap and mode — and RVVI-API, the
> C interface that steps the model and injects asynchronous events. It assumes a scalar hart: one
> PC, one register file, one retirement per instruction, and no thread mask — so it does not
> transfer to SIMT as-is. I followed the core-v-verif `uvma_rvvi` architecture — dedicated
> interface, UVM monitor, analysis port — but carried transaction records instead of pins, because
> a parameterized interface would have made `virtual rvvi_if` a different type per configuration
> and broken config-genericity. My record extends the RVVI field set with warp id, SIMD group,
> thread mask, and a per-lane data array, plus a `kind` tag because load data isn't observable at
> the commit arbiter and needs a second stream. Probes self-register their interface instance in a
> package registry at time zero, so the monitor discovers however many cores were elaborated
> without any path enumeration."

---

# Quick reference

| | |
|---|---|
| Standard | RVVI — RISC-V Verification Interface (Imperas → open; used by OpenHW core-v-verif, ImperasDV) |
| Two halves | **RVVI-TRACE/VLG** (DUT signals) · **RVVI-API** (reference-model control) |
| Alignment key in RVVI | `order` — monotonic retirement counter |
| Alignment key here | `uuid` — also encodes `(core, warp)` in bits [43:32] |
| Pattern followed | core-v-verif `uvma_rvvi` — interface → monitor → analysis port |
| Level | **Transaction (records)**, not signal-level pins — for config-genericity |
| Streams | **Two** — `KIND_COMMIT` and `KIND_LOAD` (because of finding R8) |
| SIMT extensions | `wid`, `sid`, `tmask`, per-lane `data[]` — none exist in RVVI |
| Discovery | `rvvi_registry_pkg` — probes self-register at time 0, monitor snapshots after `#1` |
| Loss protection | Persistent queue + `extract_phase` final sweep |
| Default state | Inert (`+LOCKSTEP` gated); off ⇒ byte-identical runs |
| Scope limit | Writeback-domain only — branches indirect, stores via end-state compare |
