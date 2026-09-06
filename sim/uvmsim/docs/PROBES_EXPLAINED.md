# Probes — the concept, and the six in this project

*Read from live source: `tb/vx_{commit,lsu,sched,instr,dcr,cache}_probe.sv` and the `bind`
statements at `tb/vortex_tb_top.sv:970-1060`.*

---

# PART 1 — Probes as a general concept

## 1.1 What a probe is

A **probe** is a passive observation module attached to the *inside* of the DUT, giving the
testbench visibility of signals that never reach the device's ports.

Black-box verification sees only the boundary. That is enough to render a **verdict** ("did the
program produce the right memory image?") but not enough to **attribute** a failure, or to measure
whether a microarchitectural feature was ever exercised. A probe closes that gap without changing
the design.

## 1.2 The mechanism: `bind`

SystemVerilog's `bind` instantiates a module into another module **from outside**, without editing
the target:

```systemverilog
bind VX_commit vx_commit_probe u_commit_probe (
    .clk(clk), .reset(reset), .commit_arb_if(commit_arb_if)
);
```

This says: *"into every instance of module type `VX_commit`, instantiate a `vx_commit_probe` and
connect these signals."*

**Why `bind` and not a hierarchical reference** (`dut.vortex.g_clusters[0]...core.commit.sig`):

| | Hierarchical path | `bind` |
|---|---|---|
| Scales with config | ✗ — needs a generate loop per level | ✓ — **automatic**, one per module instance |
| Survives RTL refactor | ✗ — a renamed level breaks it | ✓ — keyed on module *type* |
| Needs path enumeration | ✗ — must know the topology | ✓ — none |
| Requires editing the DUT | ✓ never | ✓ never |

**One `bind` statement covers 1 core or 8 cores, 1 cluster or 4, with zero testbench edits.** That
is the single most important property of this observability layer.

## 1.3 The cardinal rule: probes observe, scoreboards judge

> **All white-box visibility is passive and is never a checker.**

A probe may **read** DUT signals; it must never drive them, and it must never render a pass/fail
verdict. Verdicts come from the two scoreboards. The separation matters for three reasons:

1. **A probe that drives is a probe that changes the thing it measures.** If a backdoor *write*
   went into a register the golden model tracks, the model silently desynchronizes and every later
   comparison is meaningless — a green run that verified nothing.
2. **A probe that judges couples coverage to correctness.** A white-box checker that fires because
   the *probe's* model of the microarchitecture is wrong looks exactly like a DUT bug.
3. **Observability must not perturb.** Capture is plusarg-gated here, and with the gate off runs
   are proven byte-identical to the plain environment.

## 1.4 What probes are used for

- **Coverage** — did this feature actually execute? (divergence depth, instruction classes,
  cache hit/miss)
- **Reference-model comparison** — supply the retirement stream that lockstep consumes
- **Closing observability gaps** — recover a value that is structurally invisible at the boundary
- **Creating a read path that does not exist** — e.g. a write-only register bus

---

# PART 2 — The six probes in this project

| Probe | `bind` target | Instances | Purpose |
|---|---|---|---|
| `vx_commit_probe` | `VX_commit` | one per core | Retirement stream → lockstep |
| `vx_lsu_probe` | `VX_lsu_slice` | one per LSU slice | True per-lane **load** data |
| `vx_sched_probe` | `VX_schedule` | one per core | Warp state, divergence, barriers |
| `vx_instr_probe` | `VX_dispatch` | one per core | Instruction-class coverage |
| `vx_dcr_probe` | `VX_dcr_data` | one per core | **Read path** for a write-only bus |
| `vx_cache_probe` | `VX_cache_bank` | one per bank per cache | Hit/miss, MSHR pressure |

Two feed **checkers** (commit, LSU → lockstep; DCR → RAL). Four feed **coverage**.

---

## 2.1 `vx_commit_probe` — the retirement stream

**Taps:** `commit_arb_if[ISSUE_WIDTH]` — the commit arbiter, capturing
`{uuid, wid, sid, tmask, PC, wb, rd, data[], sop, eop}` per lane.

**Gate:** `valid && ready && wb` — a real retirement that produces an architectural result.

**Three details that make it robust:**

```systemverilog
// 1. Degenerate-config guard: NDEBUG collapses UUID_WIDTH to 1,
//    which would silently destroy the lockstep alignment key.
initial assert ($bits(commit_arb_if[0].data.uuid) > 1)
    else $fatal(1, "[P1-PROBE] uuid width=%0d <= 1 -- degenerate UUID config", ...);

// 2. Lane count derived from the signal itself, never a macro:
localparam LS_LANES = $bits(commit_arb_if[0].data.data)
                    / $bits(commit_arb_if[0].data.data[0]);

// 3. PC converted to a full byte address so it matches the model's PC:
rec.pc = to_fullPC(commit_arb_if[i].data.PC);
```

It also carries the **`+LOCKSTEP_INJECT`** hook — flip one bit of the first captured lane, exactly
once, globally, to prove the comparator is non-vacuous. Default off.

---

## 2.2 `vx_lsu_probe` — closing an observability gap that was hiding bugs

**This probe exists because of finding R8, and the reasoning is the most interview-worthy part of
the whole probe layer.**

**The problem** (from the file header): load *data* is **not observable at the commit-arb tap**.
Loads finish via the asynchronous LSU memory-response path, so the commit `data` field carries a
stale value for `lw`. The lockstep scoreboard therefore had to **skip the per-lane data compare
for loads**, checking only PC/rd/ordering, and leaving load correctness to the end-state memory
check.

**Why that blind spot mattered:**

> *"That blind spot is exactly what hides an upstream diverging load until it surfaces downstream
> at a compute op (OBS-009 `mulhsu`, OBS-010 `div`)."*

A wrong load value stayed invisible until some *later* arithmetic instruction produced a wrong
result — so the failure was reported at the wrong instruction, dozens of retirements away from its
cause.

**What it taps:** `VX_lsu_slice.result_if` — the slice's **output**, after the load-response
buffer and sign/zero extension (`rsp_buf → rsp_arb → result_if`). For a load, `result_if.data.wb==1`
and `data[]` holds the **final aligned per-lane register value**, tagged with the same `uuid` the
commit stage retires.

**How the two streams join:** the scoreboard **overlays** this record onto the matching commit
retirement **by `uuid`** — which is why the record carries a `kind` field (`KIND_COMMIT` /
`KIND_LOAD`) for routing. That is the second RVVI stream.

---

## 2.3 `vx_sched_probe` — warp state, divergence, reconvergence

**Taps:** `warp_ctl_if`, `schedule_if`, `active_warps`, `stalled_warps`, `barrier_ctrs`, and the
internal join wires (`join_valid`, `join_is_dvg`, `join_is_else`, `join_tmask`).

**Three covergroups:**

| Covergroup | Coverpoints |
|---|---|
| `sched_state_cg` | `cp_active_warps`, `cp_stalled_warps`, `cp_sched_wid`, `cp_occ`, `cross_wid_occ` |
| `divergence_cg` | `cp_is_dvg`, `cp_then_occ`, `cp_split_depth`, **`cross_dvg_depth`** |
| `reconverge_cg` | `cp_join_dvg`, `cp_join_else`, `cp_join_occ`, `cp_join_depth`, `cross_join` |

**This is where divergence-stack depth comes from** — `warp_ctl_if.dvstack_ptr`, the IPDOM stack
pointer, observed via the scheduler. Max reachable depth is bounded by the RTL's own
`DV_STACK_SIZE = UP(NUM_THREADS-1)`, and the probe derives its bins from that rather than
hardcoding.

**A methodological detail:** `cp_occ` is **weight-0** — it exists only to feed the
`cross_wid_occ` cross. Counting it twice would distort the coverage denominator.

---

## 2.4 `vx_instr_probe` — and a coverage-modelling lesson worth repeating

**Taps:** `dispatch_if` — instructions at the Issue→Execute handoff.

**The design lesson, from the file's own header:**

> A previous revision used **ONE covergroup type** carrying every class's op coverpoint, gated by
> `iff (ex_class == N)`. That meant each of the 5 bound instances **dragged in ~4 op-coverpoints
> it could never hit**, plus a 5-way conditional.
>
> This revision uses **one covergroup TYPE PER CLASS** (ALU / LSU / SFU / FPU / TCU). Each
> instance carries only the coverpoints that can actually fire for its unit.

**Why this matters beyond tidiness:** unreachable bins inflate the denominator and then have to be
*waived* — and a waiver is a claim you must justify with an RTL citation. Structuring the model so
the unreachable bins are **never created** is strictly better than creating and then waiving them.

Each class covergroup carries `cp_<class>_op`, `cp_active_threads` (the thread-mask occupancy) and
`cp_warp`.

**Config-genericity without the macro** (`:83`):
```systemverilog
// The `SIMD_WIDTH macro is not visible in the UVM compilation domain,
// so derive the width from the signal instead:
localparam int SIMD_W = $bits(dispatch_if[0].data.tmask);
```
Bins then span `[2 : SIMD_W-1]` for `partial` and `SIMD_W` for `uniform` — correct at any width.

---

## 2.5 `vx_dcr_probe` — creating a read path that does not exist

**The situation:** `VX_dcr_bus_if` is **write-only in the RTL**. There is no frontdoor read. So
"did this configuration write actually land in the register?" was, before this probe,
**unanswerable**.

**The solution:** bind into `VX_dcr_data` and tap `dcrs` — the module's **internal storage
register** — alongside the write channel:

```systemverilog
bind VX_dcr_data vx_dcr_probe u_dcr_probe (
    .clk(clk), .reset(reset),
    .write_valid(dcr_bus_if.write_valid),
    .write_addr (dcr_bus_if.write_addr),
    .write_data (dcr_bus_if.write_data),
    .dcrs       (dcrs)          // ← INTERNAL storage
);
```

This feeds the RAL predictor, turning the register mirror into a **real check**. Measured: 15/15
observations checked, 0 failed — the RTL stored every write correctly, including `MPM_CLASS`'s
8-bit truncation.

**Two properties recorded at the bind site:**

- **Config-aware by construction** — `VX_core.sv:82` instantiates `VX_dcr_data` once per core, so
  this creates exactly one probe per core the config actually built. No path enumeration.
- **⚠ PEEK ONLY** — *"it never drives, so the DCR waveform (and therefore the SimX feed at
  `vortex_scoreboard.sv:403`) is unchanged."* A backdoor **write** here would silently desync the
  golden model. This is rule 1.3 stated as a concrete hazard.

---

## 2.6 `vx_cache_probe` — the most config-aware of the six

**Taps:** `VX_cache_bank` — *"the stage where hit/miss is actually resolved."* One instance per
bank per cache, so **L1 I$, L1 D$, L2 and L3 land as separate covergroup instances** in the UCDB
hierarchy.

**Covergroup `cache_event_cg`:** `cp_event`, `cp_hit`, `cp_rw`, `cp_replay`, `cp_mshr_stall`, and
`cross_rw_hit`.

### ⭐ Config-awareness by construction — the pattern to steal

> `VX_cache_wrap.sv:160` instantiates `VX_cache` — and hence `VX_cache_bank` — **only when
> `PASSTHRU == 0`**. With L2/L3 disabled those levels are pure bypass, no bank exists, so this
> bind creates **NO instance and adds NO bins**.

So the default L2/L3-off build keeps its coverage denominator untouched, and **there is no
unreachable 0% block to waive.** The header names the failure mode this avoids:

> *"the failure mode that made the TCU covergroup a dead ~195-bin block before it was gated."*

### Parameters passed *through* the bind — single source of truth

```systemverilog
bind VX_cache_bank vx_cache_probe #(
    .INSTANCE_ID(INSTANCE_ID), .BANK_ID(BANK_ID),
    .CACHE_SIZE(CACHE_SIZE), .NUM_WAYS(NUM_WAYS), .WRITEBACK(WRITEBACK),
    .WRITE_ENABLE(WRITE_ENABLE),   // structural waiver key
    ...
```

**Cache geometry is never restated in the probe** — it rides in from the bank's own parameters.
That is the OBS-019 single-source-of-truth rule, and it is what prevents the testbench's model of
the cache from drifting from the RTL's.

**`WRITE_ENABLE` is the elegant part.** The icache is built `.WRITE_ENABLE(0)` (`VX_socket.sv:106`),
which makes its write and flush bins **impossible rather than unstimulated**. Passing that
parameter through the bind makes the waiver **per-instance and config-generic** — enable L2/L3 or
change the socket, and the correct caches keep their bins **with no edit to the probe**.

An `MSHR` reachability key is computed at the bind site for the same reason: the
`VX_config.vh` macros are in scope there but not inside the probe.

---

# PART 3 — The seven design principles (transferable to any project)

1. **Passive, never a checker.** Probes give observability; scoreboards give verdicts.
2. **`bind` on module type, never a hierarchical path.** Scales with config automatically and
   survives RTL refactoring.
3. **Pass parameters through the bind from the bound module.** Never restate design geometry in
   the testbench — that is how models drift.
4. **Config-aware by construction beats config-aware by waiver.** If the hardware does not exist,
   arrange for the bins not to exist either.
5. **Derive widths from signals, not macros** (`$bits(...)`) — works across compilation domains
   and any parameterization.
6. **Gate capture, and prove the gate.** Plusarg-controlled, default off, byte-identical when off.
7. **Guard the degenerate case at elaboration.** `initial assert ($bits(uuid) > 1)` turns a silent
   catastrophic misconfiguration into a loud, named failure at time 0.

---

# One-paragraph answer for the interview

> "All white-box visibility is through six passive probes, each `bind`-instantiated on a module
> type rather than a hierarchical path — so one bind statement covers however many cores the
> configuration elaborated, with no path enumeration and no testbench edit. Two feed checkers: a
> commit probe on the retire arbiter supplies the retirement stream for lockstep, and an LSU
> writeback probe supplies true per-lane load data, which the commit tap cannot see because loads
> complete on the asynchronous response path — that blind spot used to hide a diverging load until
> it surfaced at a later arithmetic instruction. A DCR probe peeks the internal register storage to
> create a read path the write-only configuration bus does not provide, which is what turns the RAL
> mirror into a real check. The other three feed coverage: scheduler state and divergence depth,
> instruction classes per execution unit, and cache hit/miss with MSHR pressure. The cache probe is
> the most config-aware — it binds to the cache bank, which the RTL only instantiates when the
> level is not in passthrough, so disabling L2/L3 removes the bins entirely instead of leaving an
> unreachable block to waive. Probes never drive, and capture is plusarg-gated and proven
> byte-identical when off."

---

# Quick reference

| | |
|---|---|
| Probe count | **6**, ~1,342 lines total |
| Mechanism | `bind` on module type — no hierarchical paths |
| Feed checkers | `commit`, `lsu` (→ lockstep) · `dcr` (→ RAL) |
| Feed coverage | `sched`, `instr`, `cache` |
| Largest | `vx_instr_probe` (370 lines) · `vx_sched_probe` (354) |
| Cardinal rule | Passive — observe, never drive, never judge |
| Gating | `+LOCKSTEP` / `+LOCKSTEP_INJECT` / `+DCR_RAL_INJECT`, all default off |
| Elaboration guard | `assert ($bits(uuid) > 1)` — catches `NDEBUG` collapse |
