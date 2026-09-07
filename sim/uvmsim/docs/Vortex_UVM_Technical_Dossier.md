# Vortex UVM — Technical Dossier
### Complete project evaluation, deep technical detail, and measured results
*Originally compiled 2026-08-25; **revised 2026-09-07** against primary sources: `docs/paper/vortex_uvm_paper.tex`, `docs/RTL_OBSERVATIONS.md`, `docs/VERIFICATION_PLAN_v2.md`, `docs/RISCVISACOV_STATUS.md`, `docs/INDUSTRIAL_TRANSFORMATION_PLAN.md`, and the live environment at `Vortex/sim/uvmsim/`. Every figure below is a measured, banked result — nothing projected.*

---

**REVISION NOTE — 2026-09-07.** Every count in this dossier was re-derived from source on this
date, not carried forward. Five figures moved and one entire contribution was missing:

| | was (2026-08-25) | **is (re-measured 2026-09-07)** | how |
|---|---|---|---|
| RTL observations | 48 | **56** (`OBS-001`…`OBS-057`; 048 unused as an entry) | `grep -oE "^#+ OBS-[0-9]{3}"` |
| SV/UVM source | 80 files, 21,510 lines | **88 files, 22,562 lines** | `find uvm_env tb uvm_tests \| wc -l` |
| Our covergroups | 17 | **23** | distinct `covergroup` declarations in `tb/` + `uvm_env/` |
| Passive taps | 5 rows listed | **11** (10 probes + RVVI shim) | file inventory, §3.3 |
| ISA-layer coverage | *(absent)* | **429/516 = 83.14%** | `cov/isacov_gaphunt/` |

**The material addition is PART III-B — the RVVI/riscvISACOV layer**, which post-dates the
original compilation and is now the project's *headline* contribution. The 2026-08-25 text
positioned SIMT lockstep as the centerpiece; that work is unchanged and still the deepest
technical result, but the contribution most defensible as *novel* is now the standards
extension. Both are presented, with the relationship between them stated explicitly.

Findings, methodology and the R1–R10 narrative below are unchanged except where a newer
measurement supersedes them — each such point is marked **⟨updated 2026-09-07⟩** inline.

---

# PART I — POSITIONING

## 1.1 The one-sentence claim

> **A complete, fully configurable UVM verification environment for a RISC-V GPGPU that extends the open RISC-V verification standards — RVVI-TRACE — to SIMT at their documented assumption boundary, and thereby attaches an *unmodified* third-party ISA coverage VIP (Imperas/OpenHW riscvISACOV) to a GPU; whose checking depth reaches per-instruction lockstep against a stepping functional reference model with every verdict class proven non-vacuous by permanent fault injection; with 94.7% total code coverage using only machine-generated RTL-cited exclusions, 83.1% third-party ISA-behaviour coverage, and ten promoted RTL findings out of 56 catalogued — including an unknown-reset X-propagation bug still present upstream.** ⟨updated 2026-09-07⟩

**Two contributions, deliberately kept distinct** — conflating them is the easiest way to lose credibility on either:

| | **the standards contribution** | **the depth contribution** |
|---|---|---|
| what it is | RVVI-TRACE extended with warp ID, thread mask and per-lane data; third-party ISA coverage VIP attached without forking it | per-instruction, per-active-lane lockstep against SimX, with five SIMT alignment rules and a two-pass load-value feed |
| why it is novel | all three open RISC-V verification standards (RVVI, riscvISACOV, ImperasDV) assume **one hart, one instruction, one architectural context** — a warp is *N* contexts under a mask | end-state comparison is the academic norm for GPU verification; this reaches instruction granularity |
| what it is evidence of | that the RISC-V verification ecosystem can be made to reach SIMT machines at all | that *this* GPU was checked deeply, not just at its final memory image |
| the honest limit | the VIP is **structurally blind to the thread mask** — proven, §III-B.4 | SimX is **co-designed with the RTL**, therefore not independent — §2.3 |

**On "first published":** the defensible framing is narrow — *an open-source UVM environment for a RISC-V-based GPGPU that extends RVVI to SIMT and integrates a third-party ISA coverage VIP.* Avoid unqualified "first ever"; prior theoretical work exists.

## 1.2 Why this is not "another UVM testbench"

Three properties separate this from a coursework-grade environment, and each is independently checkable in the repo:

1. **It reaches instruction granularity, not end-state.** Most academic GPU verification compares final memory. This compares *every retired instruction, per active SIMT lane*, against a stepping golden model — a depth that required inventing five alignment rules that no scalar-CPU lockstep flow encounters.
2. **It proves its own checkers work.** Four permanent fault-injection tests must stay RED forever. A green regression is meaningless without this, and almost nobody builds it.
3. **It found real bugs in shipping open-source RTL** — including one (R10) whose repair *lowered* a coverage number, because part of that coverage had been harvested from an illegal hardware state.

## 1.3 Scale of the artifact

*All figures below re-measured 2026-09-07 from the working tree.* ⟨updated 2026-09-07⟩

| Dimension | Measured |
|---|---|
| SystemVerilog / UVM source | **88 files, 22,562 lines** (`uvm_env/`, `tb/`, `uvm_tests/`) |
| UVM agents | **5** — host, DCR, AXI, memory, status |
| Passive RTL taps | **11** — 10 `bind`-attached probes + 1 RVVI publication shim, **zero RTL modifications** |
| Our functional covergroups (L2/L3) | **23**, each with a written sufficiency rationale |
| Third-party ISA covergroups (L1) | **80**, generated from Imperas' own DV plans across **5 extensions**, VIP **unforked** |
| Feature areas decomposed | **53** in `docs/VERIFICATION_PLAN_v2.md`, GPU-first (11 SIMT · 4 issue/scoreboard · 10 execution · 14 memory · 8 bus · 3 multi-core · 2 termination · 1 waived) |
| Directed kernels authored | **~30**, all byte-exact vs. reference (incl. `isacov_fill`, purpose-built for L1 gap-hunt) |
| Constrained-random profiles | **12** riscv-dv seed profiles (+2 excluded as *unimplementable*, with reason) |
| AXI4 SVA properties | **~15–18 protocol + 11 handshake-stability** assertions |
| RTL observations catalogued | **56** (`OBS-001`…`OBS-057`; 048 unused), each with evidence + disposition |
| Coverage banks | **3** topology banks + a separate L1 ISA bank, **never blended** |
| Papers written | **2** (full + condensed ~8pp), IEEE format, compiled |
| Packaging | Upstream-shaped backend at `Vortex/sim/uvmsim/`, peer to `sim/simx`, `sim/rtlsim` |

---

# PART II — THE PROBLEM DOMAIN

## 2.1 What Vortex is

Open-source RISC-V GPGPU (Georgia Tech; MICRO'21, CARRV). Executes **RV32IMAF plus six custom SIMT instructions** — `wspawn`, `tmc`, `split`, `join`, `bar`, `tex`. Hierarchical parametric topology: **clusters → sockets → cores → warps → threads**. Optional shared L2 (per-cluster) and L3 (per-GPU) cache tiers.

**Memory model: weakly coherent by design.** This is architecturally load-bearing for the whole verification strategy. MICRO'21 §4.1.4 states flush operations *are* the coherency mechanism. Verified structurally: **zero occurrences** of `snoop|coherent|invalidate|MESI|probe_req` across all of `hw/rtl/cache/*.sv` — only `flush` exists. L1 data cache is **per-socket**, not per-core.

**Direct consequence:** a fenceless multi-core program has **no architecturally-defined result**. Any DUT-vs-model difference there is *expected behavior, not a bug* — and a verification flow that does not model this distinction will generate false failures forever. Recognizing this early is what made the load-value-feed work (Part IV) possible.

## 2.2 Why every standard RISC-V verification tool fails here

| Standard component | Why it does not transfer |
|---|---|
| **Spike** (reference ISS) | Purely scalar. Cannot execute `wspawn`/`tmc`/`split`/`join`/`bar`/`tex`. Has no concept of a warp, a thread mask, or divergence. |
| **RVVI** (industry lockstep interface) | No transactor models per-lane thread masks or SIMT divergence state. The interface assumes one architectural context per hart. |
| **Constrained-random sequence stimulus** | **The DUT is an AXI bus *master*** that fetches its own instructions from memory. There is no sequence-item injection path to randomize. "Stimulus" means *compiled ELF programs*, not bus transactions. |
| **Standard scoreboard patterns** | Assume in-order, 1:1 instruction↔retirement correspondence. Vortex violates both (Part III). |

**This is the intellectual core of the project**: the entire mature CPU verification ecosystem is inapplicable, and the missing layer had to be built.

## 2.3 The strategic decision that unlocked it

Reading `Vortex/sim/simx/` source revealed that **SimX — Vortex's own C++ functional emulator — is already ~80% of an RVVI golden model**: it steps instruction-by-instruction, returns an RVVI-shaped `instr_trace_t`, holds full SIMT architectural state, reads back destination values, and is cleanly decoupled from the timing model (`core.cpp:223` consumes `emulator_.step()`).

**Decision: dual-reference with explicitly different roles.**

- **SimX = primary golden model.** Stepped live over DPI-C. Models SIMT natively. *Not independent* — co-designed with the RTL.
- **Spike = secondary independent cross-check.** Offline, on an exported retirement trace. Base-ISA subset only (warp 0 / lane 0, stopping at the first custom op). *Independent* — but cannot execute a SIMT kernel.

**Neither substitutes for the other, and this is stated explicitly rather than blurred.** SimX gives depth without independence; Spike gives independence without SIMT reach. The honest conclusion — *the SIMT axis has no independent reference and this is a structural ceiling, not an unfinished task* — is written into the paper's limitations.

---

# PART III — ENVIRONMENT ARCHITECTURE ⭐ *deep technical*

## 3.1 Role-inverted agent architecture

A GPGPU DUT **executes** programs; it is not **driven** by them. The environment therefore inverts conventional UVM roles:

| Agent | Role | Function |
|---|---|---|
| **host** | Active driver | Drives the launch protocol — kernel base address, argument pointers |
| **DCR** | Active driver | Device-configuration-register programming: thread counts, launch parameters |
| **AXI** | **Active *responder*** | Reactive slave backed by a memory model; services the DUT's own fetch and data traffic |
| **memory** | Active responder | Non-AXI configuration of the same model (protocol differs, model shared) |
| **status** | **Passive** | Observes busy/completion, retired-instruction count, PC |

A **virtual sequencer** coordinates launch sequences.

**Key architectural insight — tests and programs are orthogonal.** The UVM `TEST` class controls only *how* a program is launched, configured, and perturbed; the `PROGRAM` ELF controls *what* executes. They compose at build level (`make sim TEST=... PROGRAM_NAME=...`). This 2-axis decomposition is why ~30 kernels × a dozen test classes gives broad coverage without combinatorial testbench code.

## 3.2 Golden-model integration over DPI-C

SimX is linked into simulation via DPI-C: `simx_init` / `simx_load` / `simx_dcr_write` / `simx_run`, plus a per-retirement record export.

**Both RTL and SimX are rebuilt per configuration**, so DUT and reference always agree on topology. This was *verified from the build stamp*, not assumed: `sim/simx/simx_config.stamp` — written by the Makefile's `CONFIG_FILE` rule, therefore recording what the objects were *actually* compiled with — showed `-DXLEN_32 -DNUM_CLUSTERS=2 -DNUM_CORES=2 -DNUM_WARPS=4 -DNUM_THREADS=4 -DEXT_TCU_ENABLE` after a 2-cluster run.

**Golden-model crashes are trapped by a signal handler and mapped to sentinel exit codes** — so a reference-model failure is *classified*, never allowed to crash the run or silently pass it. Two distinct sentinels are deliberately kept separate:
- **`-4` GOLDEN_HALT** — model refused at a *named* PC / instruction / sub-field. The verified prefix still counts as evidence.
- **`-3` CRASH** — unknown reason.

Merging them would let an unconverted abort site masquerade as a clean halt.

## 3.3 Passive observability layer

**All white-box visibility is bound, passive, and never a checker.** This is a deliberate methodological line: probes provide *observability*, scoreboards render *verdicts*.

**Full inventory — 11 taps, every one attached by `bind`, zero RTL modifications.** ⟨updated 2026-09-07 — was 5 rows; the last four probes and the shim post-date the original compilation⟩

| # | Tap | Bound to | Captures |
|---|---|---|---|
| 1 | `vx_commit_probe` | `VX_commit` — retire arbiter of **every core** | Per retirement beat: `{uuid, wid, PC, rd, wb, tmask, per-lane data}` across all clusters/sockets/cores/issue lanes. Also `beat_cg`: SIMD beat splitting (`sop`/`eop` → single/first/middle/last) crossed with active-thread occupancy |
| 2 | `vx_instr_probe` | `VX_dispatch` | Per-execution-unit instruction classes, **operation-decoded**; thread masks; warp IDs; operand-value classes (sign, divide-corner, IEEE-754 FP class) |
| 3 | `vx_sched_probe` | `VX_schedule` | Divergence depth, split/join, barriers, warp state, IPDOM reconvergence |
| 4 | `vx_lsu_probe` | `VX_lsu_slice` | True per-lane load values *after* sign/zero extension — required because load data never reaches the commit arbiter (finding **R8**) |
| 5 | `vx_cache_probe` | `VX_cache_bank` | Hit/miss, MSHR stall, per bank; 8 instances, config-aware *by construction* |
| 6 | `vx_dcr_probe` | `VX_dcr_data` | Peek-only backdoor read path — the DCR bus is **write-only** in RTL, so no frontdoor read exists (§6.4) |
| 7 | `vx_coalescer_probe` | `VX_mem_coalescer` | Memory-coalescing behaviour (closed gap G-0, **OBS-051**) |
| 8 | `vx_hazard_probe` | `VX_scoreboard` | **Register hazards** — RAW/WAW. Yielded the structural result **OBS-055**: WAR is unreachable by construction (§8.5) |
| 9 | `vx_lmem_probe` | `VX_local_mem` | Scratchpad **bank-conflict** detection, reusing the RTL's own `req_bank_idx` decode rather than re-deriving it |
| 10 | `vx_instr_word_probe` | `VX_fetch` | Raw fetched instruction words — cross-checks that the disassembly being scored *is the binary that actually ran* (§III-B.3) |
| 11 | `vortex_rvvi_shim` | `VX_commit` | Publishes extended **RVVI-TRACE**; the third-party ISA-coverage attach point (§III-B) |

Taps 7–11 and `beat_cg` on tap 1 were added 2026-09-03…09-06 to close catalogued observability gaps; each was verified **non-vacuous** (its bins move on a targeted kernel) and **non-perturbing** (identical cycle and instruction counts to the pre-change baseline) before being accepted.

An **RVVI-style interface and UVM monitor** publishes the merged retirement stream through an analysis port, following the core-v-verif `uvma_rvvi` pattern — deliberately aligning with industry convention rather than inventing a private format.

**Critical design property: probes scale by `bind`, not by path enumeration.** Because `VX_dcr_data` is instantiated per core (`VX_core.sv:82`), a single `bind` statement creates 1 probe at 1CL/1C and NCL×NC probes at scale with **zero path enumeration and zero per-config edits**. The same principle covers the commit and cache probes. This is what makes the environment genuinely config-generic rather than config-parameterized.

**Lockstep capture is plusarg-gated, and with the gate off runs are proven byte-identical to the plain environment** — so the observability layer cannot perturb the results it observes.

## 3.4 The two checkers

**(1) Bidirectional end-state scoreboard.** After completion:
- **Forward pass** — every word the DUT wrote is compared byte-exact against SimX (up to **32,836 words** in one test).
- **Reverse pass** — every word SimX wrote that the DUT *never wrote* is checked. **This is what catches dropped stores**, a failure class the forward pass is structurally blind to.

Refinements: per-byte validity masking for sub-word stores; IEEE-rounding-legitimate FP differences tolerance-compared; read-only/GOT sections excluded by region.

*Architectural note:* the scoreboard was later **collapsed to a single source of truth** — a parallel 64-bit "shadow memory" reconstructed from snooped write transactions was **deleted**, and the DUT value now comes only from the preloaded memory model written byte-accurately by both responders. A reconstruction can drift from reality; the memory model is a strict superset and cannot. The memory model is now `uvm_fatal` if absent — a missing DUT side would otherwise yield a green run that compared nothing.

**(2) Lockstep scoreboard** — every retired instruction compared per active SIMT lane (Part IV).

**(3) A third, orthogonal gate makes the verdict assertion-aware**: any RTL runtime assertion firing fails the run with a distinct exit code, and failing runs are **excluded from coverage merging** (so a bank can never be contaminated by a failing run). A dedicated negative test — a deliberate misaligned load whose value is discarded — keeps this gate honest: it must fail *through the assertion path alone* while both scoreboards pass.

## 3.5 Protocol assertions and stress modes

An AXI4 SVA layer (~15–18 protocol properties + 11 handshake-stability assertions) checks burst legality, outstanding-count consistency, and signal stability under backpressure, inline on the DUT's AXI interface.

Three slave-side stress modes, all plusarg-gated and **proven byte-identical when off**:
- **throttle** (`+AXI_THROTTLE`) — injects ready wait-states, exercising `aw`/`w`/`ar` stability properties (moved those assertions 84.78% → 93%).
- **flood** (`+AXI_FLOOD`) — streams R beats back-to-back, forcing internal backpressure.
- **error injection** (`+AXI_INJECT_ERR`) ⟨added 2026-09-06⟩ — returns `SLVERR`/`DECERR` on every 7th B/R response. This produced **OBS-057** (§8.6) and closed four SVA `cover` properties that had been written and never fired.

---

# PART III-B — RVVI EXTENDED TO SIMT, AND A THIRD-PARTY ISA VIP ON A GPU ⭐⭐ *the standards contribution*

*This part post-dates the original 2026-08-25 compilation and is the project's headline novelty claim.* ⟨added 2026-09-07⟩

## III-B.1 The gap, stated precisely

Three open standards exist for RISC-V processor verification. **All three assume a scalar core** — one hart, executing one instruction, holding one architectural context:

| standard | what it is | the scalar assumption |
|---|---|---|
| **RVVI-TRACE** | the retirement-trace interface | one record per hart: one PC, one destination register, one value |
| **riscvISACOV** | Imperas/OpenHW functional-coverage VIP; covergroups generated from the ratified ISA | one instruction, one set of operands |
| **ImperasDV** | the commercial reference-model / verdict flow | one architectural context |

**A warp is *N* architectural contexts executing one instruction under a thread mask.** One record per hart cannot carry that. This is not an implementation inconvenience — it is the interface's stated assumption, and it is exactly where the extension had to be made.

## III-B.2 What was done

RVVI-TRACE was extended **at its documented assumption boundary** — adding warp ID, thread mask and per-lane data — and the unmodified third-party coverage VIP was attached to the extended interface.

> **The VIP was never forked.** Five ISA extensions were generated from Imperas' own DV plans, and **80 of its covergroups run against a GPU.**

That is the claim, and it is the narrowest form that is still true: *the open RISC-V verification standards were extended to a SIMT machine, and a third-party ISA coverage VIP was made to work against a GPU without modifying it.*

## III-B.3 The mechanism — and the non-obvious discovery that made it cheap

```
kernel.elf --objdump--> PC-keyed disassembly map --.
                                                    +--> riscvISACOV covergroups
VX_commit retirement --> vortex_rvvi_shim --> rvviTrace
VX_fetch  instr word --> vx_instr_word_probe --> cross-check the map
```

**The discovery: riscvISACOV keys on disassembly *text*, not the instruction word.** `RISCV_coverage_base.svh:1381` does `$sscanf(disass,"%s %s %s")` and returns the second token; `RISCV_instruction_base.svh:119` parses register numbers out of that same string.

**Proven empirically rather than inferred:** the *identical* retirement scored **0.00%** with `disass="addi x5,x0,10"` and **2.55%** with `"00a00293 addi x5,x0,10"` — the leading hex word is load-bearing.

**Consequence: no new decode logic was needed.** Every kernel already ships a `.dump`, and `objdump -d -M numeric,no-aliases` emits exactly the required form. **Both flags are load-bearing** — `numeric` because the model tests `ops[i].key[0]=="x"`, `no-aliases` because pseudo-instructions match no covergroup. Vortex's custom SIMT ops render as `.4byte 0x...` and correctly match nothing, which is the desired behaviour rather than a failure.

**Why tap 10 exists.** `vx_instr_word_probe` answers exactly one question: *is the disassembly being scored the binary that actually ran?* It compares the fetched word against the map's word at every PC. This is not hypothetical caution — **the project had already been burned by a stale ELF surviving a source change** (`fft_par16`, 2026-09-01). Result on every run since: **0 map misses / 0 word mismatches.**

**Supporting artifacts built:** a dvplan→SystemVerilog generator (`gen/gen_ext_coverage.py`) because Imperas publishes DV plans for all 143 extensions but source for only one; 61 lines of `idvPkg`/`idvApiPkg` stubs; our own `rvviRefCsrIndex` in DPI-C; a shadow stub for a shipped-but-missing `RISCV_coverage_vectors.svh`; and a new `csr_probe` kernel covering all six Zicsr forms.

## III-B.4 ⭐ The three-layer coverage model — and the disjointness proof

The central methodological finding: **our coverage model and the third-party ISA model share no bin at all.** That is not redundancy to eliminate; it is a layering to make explicit.

| layer | question it answers | owner | blind to |
|---|---|---|---|
| **L1 — ISA** | was the *instruction space* exercised? mnemonic, register index, operand sign, immediate | **riscvISACOV** — third party, independent | **everything SIMT** |
| **L2 — microarchitecture / SIMT** | was the *machine* exercised? warps, masks, divergence, coalescing, banks, hazards, caches | **ours** (23 covergroups) | operand values, per-mnemonic identity |
| **L3 — system / protocol** | was the *interface* legal and stressed? | **ours** (SVA + collector) | — |

**That L1 and L2 are disjoint was proven, not assumed.** The VIP was run in two modes on the same kernel: `+ISACOV_MODE=A` (lane-as-hart, **4,581 lane samples**) and `MODE=B` (lane 0 only, **1,677 samples**). Both cover the **identical bin set** — only hit counts differ. Banked as `cov/bank_2CL_2C_4W_4T_ISACOV_{with,without}_20260904`.

> **SIMT lane diversity buys zero ISA-coverage bins. The third-party VIP is structurally blind to the thread mask** — which is precisely why L2 exists and why the two must never be merged.

**Rule: never merge L1 and L2 UCDBs; never quote a blended number.** Different denominators over different axes.

## III-B.5 The L1 result, and the honest denominator argument

| stage | bins | coverage |
|---|---|---|
| raw, everything included | 1,444/6,469 | 22.32% |
| + structurally unreachable excluded (**EUR**) | 1,444/6,467 | 22.33% — *hit count unchanged, machine-gated* |
| **+ register-index bins excluded (EOTH) — the quotable figure** | **429/516** | **83.14%** (89.28% weighted) |

**78 of 80 covergroups carry real coverage.** The campaign drove this from a standing start: `vecadd_lite` baseline (546 bins) → directed kernels → the purpose-built `isacov_fill` kernel → 1,444 bins.

**Why register-index bins are excluded — state this on the slide, never hide it.** `*_reg_assign` coverpoints ask *which* architectural register served as rd/rs1/rs2. They are **92% of the raw denominator** (5,951 of 6,469 bins), and they are excluded as a **stated scope decision, not an unreachability claim**:

1. Vortex's register file is a **banked RAM with uniform indexing** — `x5` versus `x6` is structurally symmetric; there is no per-index logic that could break.
2. **Which register the compiler allocates is a property of the compiler, not the DUT.** Reaching `x28` means manufacturing register pressure, which verifies nothing about the hardware.
3. Leaving them in makes the aggregate a measurement of the compiler's register allocator rather than of the design.

This is standard practice in CPU DV; OpenHW take the same position.

**The two exclusion classes are deliberately kept separate and differently labelled** so the distinction cannot be blurred:

- **EUR — structurally unreachable.** Asserts the bins *cannot* be hit, so removing them must change the **denominator only**. `apply_isacov_exclude.sh` **fails the run** if a structural exclusion moves the hit count. It passed: 1,444 hits before and after. Two members: `rv32zifencei_fence_i_cg` (**OBS-050** — `VX_decode.sv:291` never inspects `funct3`, so `fence.i` decodes identically to a data `fence` and `INST_FENCE_I` is a dead localparam) and `rv32i_nop_cg` (`nop` is a disassembler *alias*, and the map is generated with `-M no-aliases`, so it can never appear).
- **EOTH — reachable but out of scope by decision.** The `*_reg_assign` class above. **Not** hits-invariant, and never gated as if it were.

> The **EUR/EOTH split is itself the deliverable here.** Anyone can raise a percentage by excluding bins; the defensible move is to make the *kind* of exclusion machine-checkable and to let the two numbers be inspected separately.

## III-B.6 What the ISA layer bought that our own model lacked

Worth being concrete, because "we added a third-party VIP" invites *"and did it find anything?"*:

- **`cp_asm_count`** — a real granularity gain: per-mnemonic instruction identity, which our unit-class model deliberately abstracts away.
- **`cp_*_sign`, `cp_imm_value`** — operand-value coverage, where **we had nothing at all**. This directly motivated adding the equivalent to *our* L2 model (operand sign, divide corners, IEEE-754 class on taps 1–2), so the layers now inform each other rather than merely coexisting.
- **Four silent failures were hit during integration, none of which announced itself** — the disassembly-text keying above being the most costly. Each is catalogued in `docs/RISCVISACOV_STATUS.md §8`.

---

# PART III-C — AN ORIGINAL SIMT-AWARE STIMULUS GENERATOR (`simtgen`) ⭐ *added 2026-09-07*

## III-C.1 The gap that riscv-dv and Spike cannot close

The ten-seed sweep (§ Part X, "Stimulus diversity, not volume") already proved *volume* was not the binding constraint: 90 additional distinct riscv-dv programs bought +0.06% toggle and nothing else. The reason is structural, not a tuning problem — **riscv-dv and Spike have no concept of a warp, a thread mask, or a reconvergence stack**, so neither can *intentionally* provoke a divergent branch, a bank-contending memory access, or a coalescable-vs-scattered pattern. They generate scalar programs; a SIMT hazard can only appear in one by accident.

## III-C.2 A negative result, reached honestly, before building anything

An external academic SIMT fuzzer (FuzzGPU, USENIX Security 2026) was evaluated for reuse of its *generator* specifically (never its checking stack, which duplicates work this project already does differently). Its generator turned out to be **execute-in-the-loop coupled to a vendored ISA-emulator instance**, built by one CMake target that also pulls in Verilator/ramulator/softfloat, with no generator-only build path. Extraction cost was judged to exceed reimplementation cost. Full citation-backed writeup: `docs/GENERATOR_SCOPING_DECISION.md`. **Only the published axis taxonomy (divergence / memory-access-pattern / barrier-sync) was reused, as a category label — no code, no algorithm.**

## III-C.3 Design principle and the six enforced constraints

`simtgen` randomizes at the *program* layer only — the existing SimX lockstep and end-state scoreboard do all correctness checking, unchanged. The generator's only job is to produce *interesting* programs; it carries no self-check of its own. Every generated program enforces:

1. **Race-free by construction** — each thread/warp writes only its own memory slice (Vortex is weakly coherent, flush-only).
2. **Divergent control flow is real C `if`/`else`**, never hand-written assembly.
3. **Grid size is device-derived at runtime** (`vx_num_cores()*vx_num_warps()*vx_num_threads()`), never hardcoded to one topology.
4. **No self-check** — SimX is the reference.
5. **Bounded live values** (≤ 8–16) — measured register-spill / spawn-join deadlock risk above that.
6. **Seeded, deterministic** — one `random.Random(seed)` instance threaded through everything; verified by generating the same seed twice and diffing.

## III-C.4 A compiler defeated the first version, and how that was caught

The first divergence-axis generator produced nested `if` trees intended to walk the IPDOM reconvergence stack to its full depth. It silently failed: **LLVM folded the pure-arithmetic divergent body into a lookup table**, collapsing the intended structure to two real `vx_split_n` sites instead of four — caught by reading the compiled disassembly, not by trusting a functional pass. Fixed with a one-line change: the shared accumulator became `volatile int r`, forcing real memory ordering and restoring genuine nested split/join structure.

## III-C.5 A second, independent stimulus/compiler path — POCL

`simtgen` is complemented by validating a wholly separate code-generation path: **POCL** compiles real OpenCL-C kernels through a Vortex-targeted `llvm-vortex` toolchain onto the same DUT. Built and run end-to-end this session (`tests/opencl/saxpy`, via `sim/simx`): **PASSED, instrs=41601, cycles=41711, IPC=0.997363** — independently re-run with identical numbers. Two real environment gaps were found and fixed to get there (missing `LD_LIBRARY_PATH` entries; `Vortex/runtime/simx/libvortex-simx.so` had never been built in this environment). This proves the flow isn't exercised through only one code-generation path — a claim `simtgen` alone cannot make.

## III-C.6 Results — bins closed that the industry stack left at 0%

| Covergroup bin | Before `simtgen` | After |
|---|---|---|
| `warp_divergence_cg.cp_split_depth` (4 depths) | 3/4 — `d[3]` never hit across 50 riscv-dv-style seeds | **4/4 = 100%** |
| `lmem_bank_cg.cp_bank_conflict` | 0/3 — probe itself was miscoded (§7.5, OBS-060) | **3/3 = 100%** |
| `coalesce_cg.cp_coalesce_kind` | partial | **3/3 = 100%** |

⚠ **These closures are verified in isolated merge directories** (`cov/simtgen_*_20260907/`), the same discipline as the ISA layer (§III-B.5) — **not yet folded into the frozen topology banks in §7.4.** A full-suite re-run to fold them in is a genuine multi-hour cost, tracked as roadmap item 9, not launched speculatively.

An early development iteration of the memory-axis generator had a real bug (`base=wid*nt` instead of `base=wid*nt*nt`), which produced genuine cross-warp address collisions — caught as **6/6 real scoreboard MEM MISMATCH failures** before the fix, which is itself evidence the bidirectional scoreboard was watching.

---

# PART IV — FLAGSHIP: PER-INSTRUCTION LOCKSTEP FOR SIMT ⭐⭐ *the technical centerpiece*

## 4.1 Architecture

The DUT probe stream and the SimX per-retirement stream meet in a lockstep scoreboard that **aligns both streams per (core, warp)** and compares each retirement **per active SIMT lane**: PC, destination register, written value.

**Four-way outcome taxonomy:** matched / field mismatch / data mismatch / **orphan** — plus **drain-empty checks on both sides**, so dropped *or extra* retirements are caught rather than silently absorbed.

## 4.2 The five SIMT-specific alignment rules

*Each rule was forced by simulation evidence, not designed a priori. These are the transferable contribution — any SIMT lockstep implementation will meet all five.*

### Rule 1 — Retire order is not program order
Within one warp, the commit arbiter retires whichever execution unit is ready first (`VX_commit.sv:56-71`). **Observed: an earlier-issued instruction retiring after two later ones.** The functional model retires in strict program order.

> **Rule: align by the per-warp issue counter (uuid), sorted — never by position or cycle.**

### Rule 2 — The golden model's uuid is not a cross-key
SimX leaves its retirement uuid at zero, so DUT and reference uuids cannot be matched directly.

> **Rule: the alignment key is per-(core, warp) program order.** The DUT uuid's *high bits* — which encode `(CORE_ID << NW_BITS) + wid` (`VX_uuid_gen.sv:40`) — supply the (core, warp) attribution **with no RTL change**.

*This is a genuinely elegant result: multi-core attribution was extracted from an identifier the RTL already generated for an unrelated purpose, avoiding any DUT modification.*

### Rule 3 — One instruction is not one retirement record
A single load can appear as **several commit records sharing one uuid with partial, overlapping thread masks** — observed masks `0xd` then `0xe` — because the LSU commits lanes as their memory responses arrive. This is *distinct from* clean SIMD-beat splitting.

> **Rule: aggregate DUT records by uuid with thread-mask *union* before comparing; never aggregate by start/end-of-packet flags.**

### Rule 4 — Load data needs its own tap *and* its own soundness filter
The commit arbiter's data field is **stale for loads** (the LSU writes the register file on its asynchronous response path). A dedicated LSU writeback probe recovers true per-lane values — **but a naive compare is unsound**: loads of uninitialized stack or local memory legitimately differ between models. **Measured: 429 false mismatches on a known-good kernel.**

> **Rule: compare a load lane only when the reference-model effective address lies in the verifiable data region *and* the golden value is not the initialization poison; defer everything else to the end-state check.**

**Result with the filter: 74 in-region lanes compared, 113 filtered, 0 false mismatches** — and the load compare is on *by default*, not disabled to avoid noise.

### Rule 5 — Performance-counter CSRs are model-divergent by definition
`mcycle` / `minstret` / `mhpmcounter*` necessarily differ between a timing-accurate DUT and a functional model (observed off-by-one).

> **Rule: the golden model flags the MPM CSR range as volatile; the comparator excludes their *data* while still checking PC and destination** — the standard RVVI exclusion class.

## 4.3 Cross-configuration validation — lane-exact across 6 topologies

**All results: zero mismatches, zero orphans.**

| Configuration | Matched writebacks |
|---|---|
| 1CL/1C/4W/4T (vector-add) | 1,035 / 1,035 |
| 1CL/1C/4W/4T (**nested divergence**) | 2,668 / 2,668 |
| 1CL/2C/4W/4T | 1,801 / 1,801 |
| 2CL/2C/4W/4T | 3,333 / 3,333 |
| 1CL/1C/2W/2T | 855 / 855 |
| 1CL/1C/8W/4T | 1,423 / 1,423 |

The nested-divergence kernel exercises **asymmetric 3v1 → 2v1 → 1v1 splits**, driving the mask-union aggregation through divergence and reconvergence — **with no comparator changes**. That the same comparator handles 2W/2T through 8W/4T and 1 through 2 clusters unmodified is the evidence that the five rules are *structural*, not tuned.

## 4.4 Independent cross-check against Spike

On `riscv_arithmetic_basic_test_0.elf`: **DUT / SimX / Spike all retire exactly 11,076 architectural writebacks and agree on every PC, destination register and value — 0 mismatches.** All 11,076 value-compared (no skips). Non-vacuity proven by injecting a fault at record 5000 → named exactly, exit 1.

**Scope stated honestly:** warp0 / lane0 / base-ISA only, stopping at the first Vortex custom op. New trace hook `+LOCKSTEP_TRACE=<path>` (default OFF) + `scripts/spike_audit.py`.

**Known observability limit (OBS-022):** lockstep is **writeback-domain only** — `nop`, `beq`, `jalr x0` never enter the stream, so a wrong branch is caught only *indirectly* via the successor's PC, and **stores are outside lockstep entirely** (the end-state compare covers them). This is exactly how Spike's 11,487 reconciles to the flow's 11,076. *Stating this reconciliation rather than quoting the bigger number is the kind of detail an interviewer will notice.*

---

# PART V — HARDEST PROBLEM: THE TWO-PASS LOAD-VALUE FEED ⭐⭐ *the research contribution*

## 5.1 The problem

A fenceless program on *N* shared-memory cores is **architecturally undefined**: any interleaving of cross-core stores is legal. A functional model stepping cores in a fixed order and a timing-accurate DUT legitimately read **different values at racy loads** — and **every downstream value forks**. One divergent load cascades into hundreds of mismatches.

End-state comparison can only classify such runs *unverifiable*. Industrial RVVI flows solve the analogous CPU problem by feeding DUT-observed load data to the reference over a "load bus." **No such mechanism existed for a SIMT multi-core.**

## 5.2 The mechanism — sound two-pass trace replay

```
Pass 1 — lockstep run
   DUT vs. reference; in-region loads compared per lane
        ↓
capture divergent racy loads
   key (cid, wid, PC, occurrence) → per-lane DUT values
        ↓
DPI load-value feed armed
   reference consumes DUT values at exactly those keys
        ↓
Pass 2 — reference re-run, full re-compare
   self-check: consumed == pushed
        ↓
residual = verdict
   0 ⇒ verified;  unexplained > 0 ⇒ hard error
   + deferred end-state compare vs. post-feed reference
```

**The key `(cid, wid, PC, occurrence)` is deliberately chosen to be robust to instructions inserted at different points in the two streams** — a positional or ordinal key would break the moment the two streams executed different instruction counts.

## 5.3 Why it cannot mask a DUT bug — three soundness properties

This is the question a sharp interviewer will ask immediately: *"aren't you just feeding the model the right answer until it agrees?"* The answer is three explicit properties:

1. **The residual *is* the verdict.** Any pass-2 divergence **not explained by a fed racy load remains a hard error**. Only the specifically-captured architecturally-undefined loads are fed; everything else is still checked normally.
2. **A `consumed == pushed` self-check guards feed alignment.** If the reference consumed a different number of fed values than were pushed, the feed misaligned and the run is invalid — detected, not hidden.
3. **Pass-1 divergences are demoted to diagnostics only when the feed is armed**, and the **end-state comparison is deferred and re-run against the post-feed reference** — so final-memory equivalence remains independently checked.

## 5.4 Flagship result

On the pinned fenceless test at **2CL/2C/4W/4T — previously undecidable**:
- Pass 1 identified **20 racy loads** causing **138 cascaded mismatches**
- Pass 2 reached **residual 0 over 5,432 / 5,432 retirements**
- The deferred end-state compare **passed**
- Injection guards remained **red**; the default no-feed path remained **byte-identical** on regression kernels

> **The run is *positively verified* equivalent modulo the architecturally-undefined racy loads — not merely excused.** That distinction (verified vs. waived) is the whole point.

| Test class | Pass-1 cascade | Residual after pass 2 |
|---|---|---|
| **fenceless** | 138 | **0** ✅ fully verified |
| interrupt-random | 116 | 7 (soundness boundary) |
| random-jump | 95 | 15 (soundness boundary) |

## 5.5 Failure localization — instruction-exact root cause

The same replay pinpoints first divergences exactly. For the fenceless case:

- First divergent instruction: **`mulhu s0,s3,a3` at PC `0x800004f4`, sequence 278** — **cluster-1 cores only; cluster-0 byte-exact**
- The divergence is **already present in its *inputs***: an upstream shared load at `0x80020618` where the **DUT reads the pristine ELF initialization value `0x7aea0e77`** while the **reference — having interleaved another core's store first — reads `0x7a000e77`**

> **This confirms, at instruction granularity, a reference-model memory-ordering artifact and *not* a DUT bug. End-state comparison alone could never make that distinction.**

*This single result is probably the strongest thing in the project to walk an interviewer through: it demonstrates the flow doesn't just detect a difference, it attributes blame correctly to the model rather than the hardware, with a named instruction, PC, sequence number, cluster, and both conflicting values.*

## 5.6 The soundness boundary — stated, not hidden

**Where the method provably stops working:**

**(a) Asynchronous interrupt timing (residual 7).** Proven **keying-independent**: re-keying the feed from a per-warp ordinal to `(cid, wid, PC, occurrence)` leaves the residual *identical*, **disproving feed-alignment artifacts**. The cause is genuine — the timing-accurate DUT and the functional model take asynchronous interrupts at **different instruction boundaries**, so an interrupt-affected path executes a different number of times. **No load-data feeding can align *when* an interrupt fires.**

> **The formal boundary: two-pass trace replay is a fixed point for *data-only* divergence; asynchronous-input timing requires a *step-follower* reference.**

**(b) Control-flow-steering races (residual 15).** When racy loaded bytes steer control flow, pass-2 replay walks a *different path* and meets **fresh racy loads the pass-1 trace never keyed**. Two-pass replay has **no fixed point when races feed branches**; an iterated (bounded fixed-point) feed or a step-follower is required.

**Disposition in both cases: end-state VERIFIED, instruction-granularity residual classified — the verdict is left honestly red, not forced green.**

---

# PART VI — VERDICT TAXONOMY AND NON-VACUITY ⭐ *the discipline argument*

## 6.1 Four verdict classes

Every run renders one of: **PASS** / **FAIL** / **UNVERIFIABLE** / **END-STATE-VERIFIED** (with instruction-granularity residual).

**`UNVERIFIABLE` is first-class.** A run where the golden model cannot render a verdict is classified with root-cause evidence — **never force-compared, never silently dropped, and never counted as a pass**. Most flows have only pass/fail and therefore quietly convert "I couldn't check this" into "it passed."

## 6.2 The four permanent fault-injection guards

> **Verdicts are only as good as their ability to go red.**

| Guard | Injection | Must be caught by |
|---|---|---|
| **wrong-value** | One bit of one DUT store is flipped | End-state scoreboard, forward pass |
| **dropped-store** | One DUT store is suppressed entirely | End-state scoreboard, **reverse pass** |
| **lockstep** | One bit of one retirement is flipped | Lockstep comparator, **at the exact uuid/PC/lane** |
| **assertion-gate** | Deliberate misaligned load | RTL-assertion path **alone**, while both scoreboards pass |

**All four must stay red on injection after any checker change.** Both memory guards have been re-confirmed red at the *same* faulted address (`0x800075d8`) across every subsequent refactor — including the full scoreboard rewrite that deleted shadow memory, and the R10 reset fix.

> **This discipline, rather than any single checker, is what allows the coverage and pass-rate numbers to be taken at face value.**

## 6.3 The lesson learned — a firing checker is not a DUT bug

During DCR register-abstraction-layer work, **two testbench bugs were found where the checker was wrong and the RTL was right**:

1. **Stale RAL mirror.** `set_auto_predict` only updates the model for writes issued *through* the RAL — but most DCR traffic came from legacy sequences driving the agent directly. RTL held the right value; the mirror held 0 ⇒ **11 false errors**. Fixed with a `uvm_reg_predictor` on the **monitor**, which additionally extended checking to legacy stimulus (strictly more valuable than RAL-only coverage).
2. **End-state mirror vs. historical observation.** Comparing every observation against the *final* mirrored value is wrong whenever an address is written repeatedly — a DCR sweep legitimately shows different values over time ⇒ **10 false errors**. Fixed by comparing each observation against *the write that produced it*, truncated to the model's field width.

> **Both times the correct move was to investigate which side was right, not to loosen the check.** This is the single most-transferable process lesson in the project and worth saying out loud in an interview.

**Result after fixes: 15/15 DCR observations checked, 0 failed** — the RTL stored every write correctly, including `MPM_CLASS`'s 8-bit truncation. Non-vacuity proven via `+DCR_RAL_INJECT` (default OFF).

## 6.4 The DCR backdoor — creating observability that did not exist

The DCR bus is **write-only in the RTL** (`VX_dcr_bus_if.sv:18-31`) — a frontdoor read is *impossible*. A `bind`-based peek-only probe into `VX_dcr_data` supplies the missing read side, **making "did this configuration write actually land in the register?" a checked property for the first time.**

**Explicit safety rule recorded in-tree: NEVER poke through this probe.** The scoreboard feeds SimX off the monitor, so a backdoor *write* would silently desynchronize the golden model — a green run that verified nothing. The probe is peek-only by construction.

---

# PART VII — COVERAGE METHODOLOGY AND RESULTS ⭐ *deep technical*

## 7.1 Three closure rules

**(1) Exclusions are structural, RTL-cited, and machine-generated.** A per-configuration generator (`gen_coverage_exclude.sh NCL NC NW NT`) emits every waiver with a `file:line` citation. Example: a write-response stability assertion is unreachable because the adapter hardwires `m_axi_bready = 1'b1` (`VX_axi_adapter.sv:313`). **The merge flow verifies zero ineffective waivers** — a waiver that matched nothing is a defect, because it means the citation was wrong.

Exclusions are **keyed to configuration**: the global-barrier path is excluded *only* at single-core where it is structurally unreachable, and **kept at ≥2 cores**.

**(2) Reachable-but-unhit is left RED.** Bins stimulus could reach but did not are **reported uncovered, never waived**. Example held to deliberately: 24 AXI route-slot bins at 2 clusters were left uncovered rather than waived, because the true concurrency bound (measured 3) was not derivable from RTL parameters — and *waiving on an unproven bound* was an error made once and not repeated.

**(3) Ceilings are root-caused, not asserted.** The toggle plateau (~78–82%) was traced to the write-through cache configuration (512-bit line write-data fields never driven) and constant high PC/address bits for realistic programs. **An adversarial maximum-entropy stress kernel moved aggregate toggle by +0.02%** — establishing the ceiling as *structural*, by experiment.

**A blocking hits-invariant gate** was added to the merge flow: a structural exclusion that changes a *covered* count fails the merge. **It has already caught two real waiver defects.**

## 7.2 A self-correction worth reporting

The dominant toggle-coverage contributor was originally attributed to the write-through **data** cache. Re-derivation with a **positive control** proved that wrong: the real contributor is the **read-only instruction cache** — 51,340 bins / 22,730 missing / 55.7%, versus dcache 86,604 / 9,524 / 89.0%. **26.4% of the entire toggle gap comes from one subtree**, because `VX_socket.sv:106` sets `.WRITE_ENABLE(0)`.

The counter-check that confirmed it: `rsp_data.data` toggles 45–46× on all 512 bits ⇒ the read path is fine; only the write *direction* is dead.

> **The claim was corrected in the papers when measurement contradicted it.** Being able to point at a place where you falsified your own published claim is a strong credibility signal.

## 7.3 Functional model — 23 covergroups ⟨updated 2026-09-07, was 17⟩

Spanning: instruction classes **per execution unit** (ALU / FPU / LSU / SFU / TCU, **operation-decoded**, not class-level); SIMT divergence crossed with **IPDOM reconvergence depth**; warp/thread-mask crosses; barrier / `wspawn` / `tmc` behavior; a **stall taxonomy crossed with IPC buckets**; AXI fields; DCR and host launch spaces; system state. **Each with a written sufficiency rationale** (`docs/Coverage_Model_Reference.md`).

Measured inventory: `alu_class_cg`, `axi_transaction_cg`, `barrier_cg`, `beat_cg`, `cache_event_cg`, `coalesce_cg`, `dcr_config_cg`, `dcr_write_cg`, `divergence_cg`, `fpu_class_cg`, `hazard_cg`, `host_operation_cg`, `lmem_bank_cg`, `lsu_class_cg`, `mem_operation_cg`, `reconverge_cg`, `sched_state_cg`, `sfu_class_cg`, `status_performance_cg`, `system_cg`, `tcu_class_cg`, `tmc_cg`, `wspawn_cg`.

**The six added 2026-09-03…09-06** (`beat_cg`, `hazard_cg`, `lmem_bank_cg`, `coalesce_cg`, plus the operand-value coverpoints inside `alu_class_cg`/`fpu_class_cg`/`lsu_class_cg`) each closed a catalogued gap. Two produced results worth quoting on their own:

- **`hazard_cg` → OBS-055**: RAW and WAW populate; **WAR never can** (§8.5).
- **`beat_cg`**: 4/4 bins real on the first run (`vecadd_lite`: single=1609, first=68, middle=136, last covered) — on a probe that had carried **zero covergroups** before.

**Honest open bins, deliberately left red rather than waived:** the "pure" `by_zero`/`overflow` divide corners (per-lane operand rotation means lanes rarely hit the identical corner simultaneously), and `cp_fp_class`'s `zero`/`inf`/`nan` (need dedicated special-value stimulus). Notably `cp_fp_class`'s **`denorm` bin went real organically** — a genuine denormal arose in `fpu_test` and was classified correctly by the IEEE-754 field decode.

`lmem_bank_cg`'s `conflict` bin — previously in this same "honestly red" list, attributed to a bank-friendly stimulus pattern — **is now closed, and the original attribution was wrong. See §7.5.**

## 7.4 Results — three independent banks, never blended

> **Merging coverage databases across topologies was proven invalid** (instance-set inflation deflates by-instance percentages: 2,256 → 8,275 instances). Banks are reported **per configuration**, always.

| Metric | 1CL/1C/4W/4T | 2CL/2C/4W/4T |
|---|---|---|
| Covergroup bins (raw) | **370/377 = 98.1%** | **989/1032 = 95.8%** |
| Covergroup (weighted) | **99.8%** | **99.5%** |
| Statement | 98.1% | 98.3% |
| Branch | 95.1% | 95.7% |
| Condition | 90.4% | 88.8% |
| Toggle | 82.8% | 80.5% |
| Assertion | 96.9% | 98.9% |
| Directive | 100.0% | 100.0% |
| **TOTAL** | **94.7%** | **94.6%** |
| Runs passing | **50/50** | **50/50** |
| Coverage instances | 2,256 | 8,275 |

**Third bank:** L2/L3 shared-cache tiers enabled — **51 runs, all passing, 93.2% total.**

**Fourth, separate bank — L1 ISA layer** ⟨added 2026-09-07⟩: `cov/isacov_gaphunt/`, **429/516 = 83.14%** (89.28% weighted), 78/80 covergroups real. Kept deliberately **outside** the topology banks — different axis, different denominator (§III-B.4–5).

**The frozen defence banks on disk**, so the citation is unambiguous:
`cov/bank_1CL_1C_4W_4T_DEFENCE_FROZEN_20260903` · `cov/bank_2CL_2C_4W_4T_DEFENCE_FROZEN_20260904` · `cov/bank_2CL_2C_4W_4T_L2L3_20260818` · `cov/isacov_gaphunt/`.

⚠ **Two caveats on the table above, both honest movement rather than regression:**
1. A later pair of banks including the hazard probe reads **94.66% / 94.50%** — very slightly lower, because a new probe legitimately **adds bins to the denominator**. Quote whichever bank you cite, consistently.
2. The taps added 2026-09-03…09-06 (7–11 in §3.3) are **not yet merged into a fresh full-suite bank.** They were each verified non-vacuous and non-perturbing individually, but the headline totals here predate them. A full re-run to fold them in is a genuine multi-hour cost and was not launched speculatively.

**Methodological note worth knowing:** QuestaSim's "Total" is the **unweighted mean of 7 categories**, each contributing 1/7 regardless of bin count. Therefore *the lowest category is the biggest lever* — moving Directives (16 bins) from 31% to 100% shifted the total more than moving Toggle (425k bins). This was derived arithmetically and drove prioritization.

## 7.5 ⭐ A second self-correction: the probe was wrong, not the design (OBS-060) ⟨added 2026-09-07⟩

`lmem_bank_cg.cp_bank_conflict`'s `conflict` bin had read **zero for the project's entire history**, and the standing explanation (§7.3, prior text) was a stimulus gap: "the stressing kernel's access pattern is bank-friendly by construction." **That explanation was never verified against the RTL, and it was wrong.**

The probe (`vx_lmem_probe.sv`) classified a lane as making a bank request only when `req_valid && req_ready` — but `VX_stream_xbar`'s port structure (`output wire [NUM_OUTPUTS-1:0] valid_out`, one valid bit per bank) makes **at most one lane per bank acceptable per cycle by construction**. Gating the *classification itself* on acceptance meant a genuinely-contending second lane, denied in the same cycle, was never counted as having attempted anything — the bin was **structurally unreachable as coded**, independent of any stimulus.

**Fix:** reclassify on `req_valid` alone. Re-run against a deliberately bank-hostile `simtgen` memory-axis kernel (§III-C.6): `idle=70460, no_conflict=61, conflict=169` — a bin that had never fired once now fires 169 times against the same class of stimulus that, under the old classification, would still have read zero.

> **The same lesson as §7.2, one layer deeper.** There, a coverage *attribution* was wrong (which subsystem). Here, a coverage *measurement instrument* was wrong (the probe itself was blind to the event it claimed to sample) — and the fix was in the testbench, not the RTL, not the stimulus. A 0%-hit bin is not self-evidently a stimulus gap; it can be the thing doing the counting.

---

# PART VIII — RTL FINDINGS (R1–R10) ⭐⭐ *the "I found real bugs" section*

*60 observations catalogued total (`OBS-001`…`OBS-061`; 048 unused as an entry); **10 promoted to paper findings** with disposition.* ⟨updated 2026-09-07 — was 56⟩

**The promotion criterion matters and is worth stating if asked:** an observation is promoted when it is (a) a property of the *design*, not of our environment, and (b) reproducible from a cited `file:line` plus a named run. Testbench bugs, methodology traps and observability limits stay in the catalogue — which is why the catalogue is 5.6× the size of the findings table, not because the other 46 are filler.

| ID | Finding | Class | Disposition |
|---|---|---|---|
| **R1** | JALR target LSB not cleared; odd PC propagates via AUIPC into architectural results | **Bug (ISA violation)** | Needs RTL fix; stimulus sanitized, deviation reported not hidden |
| **R2** | `STALL_TIMEOUT` uses `1**N ≡ 1`; watchdog never scales | **Bug (latent)** | Fixed; **independently fixed upstream** |
| **R3** | Misaligned access: no trap, silently retargeted/torn | Hazard | Expected per SW contract; gated by assertion-aware verdict |
| **R4** | Core self-starts from reset; DCRs have no reset value | Hazard | Worked around via reset handshake |
| **R5** | Per-warp out-of-order commit | Quirk | Handled — lockstep Rule 1 |
| **R6** | One load → multiple commit records, overlapping masks | Quirk | Handled — lockstep Rule 3 |
| **R7** | uuid encodes flat core id + warp id | Quirk | **Exploited** — lockstep Rule 2 |
| **R8** | Load data not observable at commit arbiter | Observability | Closed — dedicated LSU probe |
| **R9** | Write path fire-and-forget (`bready` tied high); **and the master has no error-handling path at all** | **Bug (robustness) — upgraded from "Characteristic" 2026-09-06** | **Measured by fault injection: 166/166 assertion firings** (§8.6, OBS-057) |
| **R10** | **Reset relay registers reset in a flop nothing resets; `reset_o` is X for one cycle** | **Bug (X source)** | **Fixed; still present upstream** |

## 8.1 ⭐ R10 — an unknown reset for one cycle, found by *restoring a silenced assertion*

**This finding is reported first in the paper because of *how* it was found rather than what it is.**

**The defect.** The design distributes reset through a relay module that **registers the incoming reset in a flip-flop which has no initial value and which nothing resets**:

```systemverilog
`PRESERVE_NET reg [R-1:0] reset_r;   // no initial value
always @(posedge clk) begin
    reset_r[i] <= reset;             // nothing resets THIS flop
end
assign reset_o[i] = reset_r[i / F];
```

Its output is therefore **unknown from time zero until the first clock edge**, so **every module instantiated behind a relay observes an unknown reset for one cycle**. A reset-conditional in such a module **takes its non-reset branch** — `if (X)` is not true — so logic intended to be *held in reset* executes, and any assertion inside that branch evaluates on unknown operands.

**How it was found — the part that matters.** A library counter ships with overflow/underflow assertions. **Those assertions fired during bring-up at 5, 15 and 25 ns** on the instruction- and data-cache miss-status counters. They were **guarded off** — rewritten to skip whenever inputs were unknown — so the environment could run. **That guard stayed for months.**

Restoring the original assertion and asking *why* it fired produced the diagnosis.

> **The assertion had been correct the entire time. What had been suppressed was the report, not the problem.**

**The fix.** The relay was replaced with an **asynchronous-assert, synchronous-deassert synchronizer**, so the relay output asserts whenever reset asserts *regardless of flip-flop state*. The counter assertions then pass **with no guard at all — twelve firings become zero** — and the local modification to that counter was **retired in favor of the unmodified upstream file**. A 51-run regression passes with assertions armed; both fault-injection guards re-confirmed red.

**Two generalizable consequences:**

1. **A checker disabled to make a bench run is a checker whose findings are lost** — and the loss is *silent and open-ended*. Here it was months, and the affected surface was **every module behind a relay**, not merely the one that happened to carry an assertion.

2. **⭐ Fixing the defect *reduced* a coverage number.** Branch coverage fell **95.1% → 94.5%**: during the unknown-reset cycle, modules behind a relay had been executing their **normal-operation paths**, and those executions **were counted as covered branches**. With reset correct, they no longer occur.

> **Part of the previously reported branch coverage had been obtained from a state that cannot legitimately arise — which no coverage metric can reveal about itself. The lower figure is reported as the correct one.**

*(Honesty note kept in the paper: two variables changed between those measurements, so the delta is indicative rather than isolated.)*

**This is the single best story in the project.** It demonstrates: assertion discipline, root-cause depth, willingness to re-open settled work, understanding that a coverage number is a *measurement of a model* rather than a truth, and the integrity to report a number going *down*.

## 8.2 R1 — JALR does not clear the target LSB

The RISC-V specification requires JALR to clear the LSB of the computed target. **Vortex omits the clear** (`VX_alu_int.sv:222` — the branch destination is the raw `rs1+imm`), and — **having no trap architecture** — cannot raise the instruction-address-misaligned exception the spec prescribes.

**Why it is not benign.** In the debug build (`PC_BITS = XLEN`, identity PC conversion) the odd bit **survives as the architectural PC**. Fetch silently word-aligns (`VX_fetch.sv:101`), so execution continues on correct instruction *words* — **but the skewed PC reaches architectural results**:
- every `auipc`/`la` computes `rd = PC + imm` and **inherits the skew**
- link-register writes **accumulate it across chained jumps** (observed `+1 → +3`)
- downstream loads/stores go misaligned, **cascading into R3**

**The trigger is spec-legal stimulus.** riscv-dv *deliberately* sets the JALR base LSB expecting the architectural clear, so **roughly half of generated jumps derail** — in a 12-profile suite, **every profile fired misaligned-access assertions (30 – 7,616 per run)**.

**Build-dependent visibility, which is the subtle part:** in the release build (`PC_BITS = XLEN−2`) a `+1` target is masked away *by representation* — **spec-correct by accident** — while a `+2` target would silently word-align where the spec demands a trap.

**Fix:** a one-line `& ~1` at the destination adder. **Because the reference model deliberately mirrors the no-clear behavior, the fix must un-mirror both models together** — a coordination detail that is easy to get wrong.

**Independently corroborated externally** ⟨OBS-058, 2026-09-07⟩: an unrelated academic fuzzing study of Vortex (FuzzGPU, USENIX Security 2026) reports the identical defect. Their `sra`-related second finding was checked against this project's pinned RTL and **not reproduced** — the shift-immediate field is signed at this commit, so the shift is genuinely arithmetic; logged as unresolved pending their PR text, not asserted either way.

## 8.3 R3 — misaligned access: silent corruption, simulation-only detection

Misaligned data access is documented-unsupported, but **the failure mode is hazardous**. Byte-enable logic truncates address low bits per access size (`VX_lsu_slice.sv:159-184`):
- a halfword access at an odd address is **silently retargeted** to the aligned slot
- an RV32 misaligned word access reads/writes **only the containing aligned word** — never crossing into the next word as byte-span semantics require
- **meanwhile the store-data shifter uses the full alignment offset**, so enable-set and data-shift **disagree**

> **Result: torn bytes at a wrong address, with no error indication to software.**

**The only detection is a simulation-only runtime assertion (`VX_lsu_slice.sv:189`), compiled out under synthesis — silicon has zero detection.** The same class recurs for CSRs: an invalid CSR access asserts in simulation (`VX_csr_data.sv:150`) instead of raising an exception.

Handling: defense in depth (assertion-aware verdict gate fails any run tripping these) **plus** an upstream enhancement recommendation. Notably, **the reference model performs the access byte-accurately at the exact address**, so any boundary-crossing misaligned access is a *guaranteed* DUT/reference divergence — **detectable per-instruction under lockstep**.

## 8.4 R2, R4, R8, R9 — briefly

- **R2:** `VX_config.vh:246` defines `STALL_TIMEOUT = 100000 * (1 ** (L2_ENABLED + L3_ENABLED))`. Intent: scale the watchdog with cache depth. Reality: **1^N ≡ 1**, threshold constant. On deep hierarchies the watchdog can fire spuriously. **One-character fix** (`10 **`). *(Independently fixed upstream — corroboration that it was real.)*
- **R4:** The core self-starts from reset (`VX_schedule.sv:230`) while base DCRs have no reset value (`VX_dcr_data.sv:27`) — **a core leaving reset before the host finishes DCR programming fetches from an undefined base.** Environment holds reset until a DCR-bootstrap-done handshake; a real integration needs the same discipline or an RTL interlock.
- **R8:** Load writeback data never reaches the commit arbiter tap — closed by the dedicated LSU probe + Rule 4's soundness filter. Additionally, **the LSU result bus broadcasts the active lane's value across all lane positions per beat** (it is not a per-lane vector), which the comparator must account for.
- **R9:** The AXI adapter hardwires write-response ready — a **fire-and-forget write path** that forfeits error observability and makes one class of response-stability assertions **structurally untestable**. **Now measured rather than inferred — see §8.6.**

## 8.5 ⭐ OBS-055 — WAR hazards are unreachable *by construction*, and that is a result ⟨added 2026-09-07⟩

The new hazard probe (tap 8) shows RAW and WAW populating normally — and **WAR never firing at all**. The tempting move is to log an uncovered bin and chase it with stimulus. Reading `VX_scoreboard.sv` instead proves it can never fire:

- the in-use register bitmap is set **only on a producer's own `rd`**, never on a source read; and
- per-warp issue is **strictly in-order**.

Therefore a later write can never chase an earlier read. **WAR is structurally unreachable, not merely unobserved.**

> **Why this belongs in a findings section rather than a waiver file:** the honest outcomes for an uncovered bin are *reach it*, *prove it unreachable*, or *leave it red*. Silently waiving it is the failure mode. Here the bin was recorded with its structural reason attached and a `file:line` citation — which is a stronger statement than coverage would have been.

This is the same discipline as **OBS-050** (`fence.i` decodes identically to a data `fence` because `VX_decode.sv:291` never inspects `funct3`, making `INST_FENCE_I` a dead localparam): the zero bin was left deliberately visible *first*, and only then excluded with the citation.

## 8.6 ⭐ OBS-057 — the AXI master has no error-handling path, proven by injection ⟨added 2026-09-07⟩

**This closes a roadmap item that was open in the 2026-08-25 text** (§XI front-end item 2: *"the bus responder always returns `OKAY`; no `SLVERR`/`DECERR` injection exists, so no error-recovery path is exercised"*).

**Method.** A plusarg-gated error mode (`+AXI_INJECT_ERR`, default OFF, same convention as throttle/flood) returns `SLVERR`/`DECERR` on every 7th B and R response.

**The step that made it safe to run, and which is the transferable part:** *before* running, the existing checker was read to confirm it already guarded the injected condition — `axi_monitor.svh` skips its inline compare when `rresp != AXI_OKAY`. Verify-before-run, rather than inject-and-interpret.

**Result, measured not assumed:** `VX_axi_adapter.sv:314` and `:333-334` carry `` `RUNTIME_ASSERT ``s requiring every response to be `OKAY`. They fired **166 times out of 166 injected errors** — an exact match to the injected cadence and to vsim's own native error tally.

> **Vortex's AXI master does not tolerate a legal AXI error response. There is no error-handling path to exercise, because there is none. Any real bus error is an unconditional RTL assertion failure.**

Two consequences:
1. **R9 is upgraded** from an inferred robustness gap to a measured one. "We didn't test this" became "we tested this, and here is exactly what breaks."
2. It **closed four SVA `cover` properties that had been written and were waiting** — `cover_bresp_slverr` / `cover_bresp_decerr` / `cover_rresp_slverr` / `cover_rresp_decerr` (`vortex_axi_if.sv:760-772`) had never fired in the project's history.

*Disposition: real RTL limitation, confirmed by actual fault injection. Recommendation upstream is an error-response path (or, minimally, a documented assumption that the interconnect never errors).*

---

# PART IX — REFERENCE-MODEL FINDINGS

**The flow found bugs in the golden model too — which is itself evidence the flow works.**

1. **Misaligned instruction fetch — found *by the lockstep itself*, fixed.** The model mis-handled the fetch that the R1 mechanism produces (which it otherwise correctly mirrors).
2. **Abort-on-unknown as an unverifiability source.** Auditing abort sites revealed **two distinct populations**, not one:
   - The **majority lay in the disassembly formatter** — *off the execution path entirely*, reached only when a trace line is printed. **Aborting there destroyed an otherwise fully-checked run because the model could not *name* an instruction.** These now emit a placeholder.
   - The **remainder are genuine semantic refusals, and for those aborting is *correct***: a golden model that *guessed* a writeback would corrupt every later comparison **while still reporting agreement**.

   Those sites now record PC, instruction word, and offending sub-field before aborting, and the co-sim layer returns a distinct **golden-halt** sentinel — so instructions retired *before* the refusal remain valid evidence and the truncated tail is excluded rather than counted as divergence.

   **Re-measuring afterwards showed the unverifiable class was already empty** — every retained profile produced real end-state comparisons. Because nothing in the suite then exercises the halt path, **it is proven non-vacuous by gated injection** (`SIMX_FORCE_HALT`), in the same discipline as the negative tests.
3. **Unpopulated retirement uuid** — forces the Rule 2 workaround; populating it would upgrade lockstep alignment to a strict 1:1 key.
4. **Timing-class divergences** and **robustness gaps** — catalogued.

**A related defect found and fixed in the co-simulation layer:** the scoreboard returned early on sentinels `-4`/`-3` but **`-2` fell through into the full comparison** — which is exactly how a *truncated golden model* (SimX hitting its own hardcoded `MAX_CYCLES` cap) became **4,115 errors that looked like DUT data corruption**, when in fact the DUT had correctly retired 577,569 instructions. Now classified UNVERIFIABLE. **`MAX_CYCLES` was additionally made overridable (`SIMX_MAX_CYCLES`), because a fixed cap cannot be correct across program sizes and core counts — and being wrong *fabricates* failures.**

---

# PART X — LIMITATIONS (own these; they read as maturity)

| Limitation | Precise statement |
|---|---|
| **No independent SIMT reference** | SimX is co-designed with the RTL, therefore not independent. Spike is independent but cannot execute SIMT. **This is a structural ceiling, not an unfinished task.** |
| **Soundness boundary** | Two-pass replay is a fixed point for *data-only* divergence. **Asynchronous interrupt timing (residual 7) and control-flow-steering races (residual 15) require a step-follower reference.** Both left honestly red. |
| **Structural coverage ceilings** | Toggle plateaus low-80s — dominated by a **read-only instruction cache** whose write-data path is elaborated but undrivable (**26% of the whole gap from one subtree**), plus write-through data caching and constant address high bits. True value reported, not gamed. |
| **No trap architecture** | Exception-path verification is **unimplementable on this DUT** (there are no exceptions). The corresponding generator profiles are excluded as *unimplementable*, **not skipped silently**. |
| **Stimulus diversity, not volume** | A **ten-seed sweep across nine profiles** produced **90 additional distinct programs** (verified distinct by content hash), **all passing, with no measurable coverage gain** — every category bit-identical except toggle at **+0.06%**. That is a *robustness* result, not a coverage one. The binding constraint is the generator's *reach*: it emits user-mode integer code with M-mode CSR writes removed, so every seed explores the same region. |
| **Coverage-model provenance** | The **L2** functional model is **self-authored rather than traced to a specification document**, so closure measures the model, not the specification. *(L1 does not share this limitation — riscvISACOV's covergroups are generated from Imperas' ratified-ISA DV plans.)* |
| **The ISA layer is blind to SIMT** ⟨added 2026-09-07⟩ | riscvISACOV covers the *instruction space*, not the machine — **proven**, not assumed: lane-as-hart (4,581 samples) and lane-0-only (1,677) cover the identical bin set. It can never speak to warps, masks or divergence. That is precisely why L2 exists, and why an L1+L2 blended number would be meaningless. |
| **The L1 headline excludes 92% of raw bins** ⟨added 2026-09-07⟩ | 83.14% is quoted with `*_reg_assign` excluded as a **stated scope decision** (`EOTH`), separately labelled from structural unreachability (`EUR`) and never merged with it. Both the raw 22.3% and the excluded 83.1% are published. Quote either — never one without naming its denominator. |
| **Latest taps not yet in a merged bank** ⟨added 2026-09-07⟩ | The five probes and six covergroups added 2026-09-03…09-06 are individually verified non-vacuous and non-perturbing, but the headline 94.7%/94.6% totals **predate them**. A full re-run to fold them in has not been done. |
| **X-propagation is not available on this toolchain** ⟨added 2026-09-07⟩ | QuestaSim 2021.2_1 here exposes **no `-xprop` flag** (verified against `vsim`/`vopt`/`vlog -help`). Given R10 was an X-source bug, this is a real gap in the flow — but it is a *tooling* limit, not an unstarted task, and should be stated that way. |
| **A configuration assumption was found false, and the fix isn't scoped yet** ⟨OBS-061, added 2026-09-07⟩ | The primary "RV32IMF" config was assumed FLEN=32 (no D-extension). **Confirmed dynamically, not just by reading source** — an isolated one-module elaboration probe, compiled into its own throwaway Questa library, reports `FLEN=64 EXT_D_ENABLED=1` (a `+define+EXT_D_ENABLE=1` in the RTL flist is listed ahead of, and overrides, the config file's own guard). Four follow-ups are explicitly **open, not resolved**: architectural reachability beyond the FPU register file; whether the frozen coverage banks in §7.4 are diluted by unstimulated D-extension logic; whether SimX's F-only model is still sound against a D-capable register file; and whether this is an intentional forward-looking choice or a real defect. |
| **Verified build** | Findings stated against the debug build (`PC_BITS = XLEN`) at one RTL pin; the release build changes the *visibility*, not the presence, of R1. |
| **Provenance disclosure** | The DUT is an open-source RTL model at a pinned revision **with locally modified files**, disclosed explicitly — *"a verification result is a statement about a specific artifact, and 'upstream, unmodified' would not describe what we ran."* |

---

# PART XI — ROADMAP (front-end vs. back-end — a strong closing slide)

**Deliberately separated, because they demand different tooling, different skills, and *different claims*.**

### Remaining front-end (RTL functional) work
⟨roadmap re-assessed 2026-09-07 — one item is now **done**, one is **not available on this toolchain**, and saying so is better than listing both as future work⟩

1. **Stimulus of a different *kind*** — privileged and exception behavior. Not more seeds (proven: +0.06% toggle from 90 programs). **Still open.**
2. ~~**Error and exception verification** — the bus responder always returns `OKAY`; no `SLVERR`/`DECERR` injection exists.~~ ✅ **DONE 2026-09-06.** `+AXI_INJECT_ERR` built and run; the finding is **OBS-057 / §8.6** — there is no error-recovery path in the DUT to exercise, and that *is* the result. The *exception* half remains unimplementable (item 4 below / no trap architecture).
3. **Formal property verification** on arbitration-heavy control (cache MSHR, commit arbitration) — where dynamic simulation is weakest and the state space is small enough for proof. **Open; no formal tool licensed here.**
4. **X-propagation and reset randomization** — uninitialized-state bugs are invisible to a two-state functional flow; several unreset elements are identified structurally but never exercised under randomized reset. *(R10 is direct evidence this matters.)* ⚠ **Correction: X-propagation analysis is NOT available on this installation.** QuestaSim 2021.2_1 here exposes **no `-xprop` flag at all** — verified against `vsim`/`vopt`/`vlog -help`, not assumed from documentation. An earlier assessment of this item as "mechanically cheap" was wrong and is retracted. Reset *randomization* remains feasible without it; X-prop needs a different tool or license tier.
5. **Configuration-matrix breadth** — three topology points sampled of a space spanning cluster, core, warp, thread and cache-tier dimensions. **Open.**
6. **Coverage-model provenance** — trace the L2 functional model to a specification document. *(L1 already has this property by construction — riscvISACOV's covergroups are generated from Imperas' ratified-ISA DV plans, which is part of why the third-party layer is worth having.)*
7. **Independent SIMT reference** — structural ceiling, not a task.
8. **Fold taps 7–11 into a fresh full-suite bank** ⟨new⟩ — the probes added 2026-09-03…09-06 are individually verified but not yet reflected in a merged headline number (§7.4 caveat 2).
9. **Close the honestly-red bins** ⟨updated 2026-09-07⟩ — ~~LMEM `conflict`~~ **done** (`simtgen` bank-hostile stride + the OBS-060 probe fix, §III-C.6/§7.5; isolated merge only, not yet in the frozen banks). Remaining: the pure divide corners, and FP `zero`/`inf`/`nan` (need special-value stimulus). Both are stimulus work with no structural obstacle.
10. **Fold `simtgen`'s closures into a fresh full-suite bank** ⟨new⟩ — same caveat as item 8: individually verified, not yet merged into the §7.4 headline totals.
11. **Scope OBS-061 (FLEN=64/D-extension elaborated)** ⟨new⟩ — the four follow-up questions in Part X are open, not resolved.

### Back-end / ASIC sign-off (entirely out of scope — say so plainly)
Gate-level simulation (netlist, then back-annotated timing) · static timing analysis across PVT corners · DFT (scan, ATPG, fault coverage, MBIST) · CDC/RDC analysis with metastability modeling · lint and structural sign-off · low-power verification (power intent, retention, isolation) · physical-design closure (floorplan, P&R, extraction, SI/PI) · equivalence checking RTL↔netlist↔post-layout · post-silicon bring-up and characterization.

> **"The front-end items would raise the strength of the claims made here; the back-end items are prerequisites for a *different claim entirely* — that the design is manufacturable and will function in silicon. Nothing in this work speaks to the latter."**

**Being able to draw that line crisply is itself a hiring signal** — it shows you know what verification sign-off actually means at an industrial scale, and you are not overselling front-end work as tape-out readiness.

---

# PART XII — LIKELY INTERVIEW QUESTIONS & ANSWERS

**Q: "Isn't the load-value feed just feeding the model the right answer until it agrees?"**
> No — three properties prevent that. (1) The residual *is* the verdict: any pass-2 divergence not explained by a specifically-captured racy load remains a hard error. (2) A `consumed == pushed` self-check catches feed misalignment. (3) The end-state compare is deferred and re-run against the post-feed model, so final-memory equivalence is still independently checked. And empirically, the guards stay red and the two boundary cases (interrupt, control-flow races) are left *honestly red* rather than forced to zero.

**Q: "Your golden model was written by the same people as the RTL. What does agreement prove?"**
> Less than it appears, and I say so in the paper. SimX is co-designed and therefore not independent — a shared misunderstanding would cancel. That is why Spike is in the flow: DUT/SimX/Spike agree on 11,076/11,076 writebacks on the base-ISA subset, which is genuine three-way independence. But Spike cannot execute SIMT, so **the SIMT axis has no independent reference — a structural ceiling I state as a limitation, not a to-do.**

**Q: "A green regression proves nothing. How do you know your checkers work?"**
> Four permanent fault-injection tests that must stay red forever: wrong-value, dropped-store, lockstep-bit-flip, and assertion-gate. Both memory guards have re-fired at the same address across every refactor since, including a full scoreboard rewrite. There is also a documented case (OBS-029) where I proved a *green* run can be vacuous: DUT and model execute the same binary, so a fault in the *stimulus* is common-mode and cancels — which I guard against at runtime.

**Q: "Why did your coverage go down?"**
> Because I fixed a real bug. R10 — a reset relay driving X for one cycle — meant modules behind it executed normal-operation paths during reset, and those executions were counted as covered branches. Fixing it dropped branch coverage 95.1% → 94.5%. **Part of my prior coverage had come from a state that cannot legitimately arise, and no coverage metric can tell you that about itself.** I report the lower number as the correct one.

**Q: "What's the weakest part of this work?"**
> Stimulus diversity. Seed control and reproducibility are solved, but a ten-seed sweep produced 90 distinct programs with **+0.06% toggle and nothing else** — because the generator emits user-mode integer code with M-mode CSR writes stripped, so every seed explores the same region. More volume buys robustness, not coverage. The real gap is stimulus of a different *kind*: privileged behavior, exceptions, and bus error responses — and the DUT has no trap architecture, so part of that is unimplementable rather than unfinished.

**Q: "Walk me through a bug you found end to end."**
> *(Use R10 — see §8.1. It has: a suppressed assertion, a months-long silent window, a concrete RTL mechanism with code, a real fix, a 51-run regression, re-proven injection guards, and a counterintuitive coverage consequence. It demonstrates every skill they are testing for in one story.)*

**Q: "You excluded 92% of the ISA coverage bins and then quoted 83%. Isn't that just moving the goalposts?"** ⟨added 2026-09-07 — expect this one; it is the sharpest attack on the headline⟩
> It would be, if I'd hidden it or if the two exclusion classes were mixed. Three things prevent that. **First, both numbers are published** — 22.3% raw, 83.1% with register-index bins out, and the slide states which denominator it is using. **Second, the classes are separate and differently labelled.** `EUR` is a claim that bins are structurally unreachable; `EOTH` is a scope decision that they're out of scope. **Third, the structural class is machine-gated**: if an `EUR` exclusion moves the *hit* count, the script fails the run — because a genuinely-unreachable bin can only change the denominator. It passed at 1,444 hits before and after. On the merits of the scope decision itself: `*_reg_assign` asks which architectural register was allocated. Vortex's register file is a banked RAM with uniform indexing, so `x5` versus `x6` is structurally symmetric — and *which* register gets allocated is a property of the compiler, not the DUT. Leaving those bins in makes the aggregate a measurement of LLVM's register allocator. OpenHW take the same position.

**Q: "What's actually new here? Plenty of people have written a UVM environment."** ⟨added 2026-09-07⟩
> The environment isn't the contribution — the standards extension is. All three open RISC-V verification standards assume one hart, one instruction, one architectural context. A warp is *N* contexts executing one instruction under a thread mask, so one record per hart structurally cannot carry it. I extended RVVI-TRACE at exactly that documented assumption boundary — warp ID, thread mask, per-lane data — and then attached Imperas' coverage VIP to the extended interface **without forking it**: 80 covergroups generated from their own DV plans, running against a GPU. And I can prove the layers are disjoint rather than assert it: running the VIP as lane-as-hart (4,581 samples) versus lane-0-only (1,677) covers the *identical bin set*, which means the third-party model is structurally blind to the thread mask. That's why our own SIMT model has to exist alongside it, and why the two numbers must never be merged.

**Q: "Have you ever been wrong about a finding?"**
> Yes, twice, and both are in the papers. I attributed the toggle-coverage gap to the write-through data cache; a positive control proved it was the **read-only instruction cache** — 26% of the whole gap from one subtree. And I once waived AXI route bins on an assumed bound; three of those `ignore_bins` later **fired on real traffic**, which is exactly the failure mode a waiver is supposed to prevent. I withdrew them, rebuilt the coverpoints from RTL parameters, and added a **blocking merge-time gate** that fails any exclusion which changes a covered count — it has since caught two more waiver defects.

---

# PART XIII — SUGGESTED DECK NARRATIVE

| # | Slide | Core message |
|---|---|---|
| 1 | **Title** | UVM verification of a RISC-V GPGPU — per-instruction lockstep for SIMT |
| 2 | **The inversion** | GPGPU breaks every CPU verification assumption: DUT is a bus master, no reference model, no lockstep interface for SIMT |
| 3 | **Why standard tools fail** | The 3-row table (Spike / RVVI / CRV stimulus) — establishes that the missing layer had to be built |
| 4 | **The strategy** | Dual reference: SimX for depth (SIMT-native, not independent) + Spike for independence (independent, not SIMT-capable). Neither substitutes. |
| 5 | **Architecture** | Role-inverted agents · DPI-C golden model · passive bind-probe observability · two scoreboards + assertion gate |
| 6 | **⭐ Flagship: SIMT lockstep** | The five alignment rules — with the retire-order and mask-union examples spelled out |
| 7 | **Lockstep validation** | 6-config matrix, all lane-exact, 0 mismatches / 0 orphans, comparator unchanged across 2W/2T → 8W/4T |
| 8 | **⭐⭐ Hardest problem** | Two-pass load-value feed — the 5-stage diagram + why it can't mask a bug (3 soundness properties) |
| 9 | **Flagship result** | 138 → **residual 0 over 5,432 retirements** on a previously undecidable fenceless multi-cluster test |
| 10 | **Attribution, not just detection** | `mulhu` @ `0x800004f4`, seq 278, cluster-1 only; input load `0x7aea0e77` vs `0x7a000e77` → **model artifact, not DUT bug** |
| 11 | **The boundary** | Where the method provably stops: interrupt timing (7, keying-independent) and control-flow races (15). Left honestly red. |
| 12 | **⭐ Non-vacuity** | Four permanent injection guards. "Verdicts are only as good as their ability to go red." |
| 13 | **Coverage** | 3 banks, 94.7% / 94.6% / 93.2%, 100% pass — and the three closure rules |
| 14 | **⭐⭐ R10** | The suppressed assertion → unknown reset → **fixing it lowered coverage**. The best story in the deck. |
| 15 | **Findings table** | R1–R10 with class + disposition; R1 (ISA violation) and R3 (silent corruption in silicon) called out |
| 16 | **Self-correction** | Toggle attribution falsified by positive control; waivers that fired on real traffic → blocking merge gate |
| 17 | **Limits** | Independence ceiling · soundness boundary · structural toggle ceiling · stimulus diversity ≠ volume |
| 18 | **Roadmap** | Front-end (raises claim strength) vs. back-end (a different claim entirely). Draw the line explicitly. |
| 19 | **Artifact** | 22.5k lines / 88 files / 5 agents / 11 taps / 23 covergroups (+80 third-party) / 56 observations / 2 papers / upstream-shaped packaging |

**⟨2026-09-07 — the narrative above is the *depth-first* ordering, and it now under-sells the headline.⟩** With PART III-B added, the standards contribution should be introduced **before** the lockstep flagship, because it is the more novel claim and it reframes everything after it. Suggested insertions:

| after | new slide | core message |
|---|---|---|
| 3 | **⭐⭐ The standards gap** | RVVI / riscvISACOV / ImperasDV all assume one hart, one instruction, one context. **A warp is *N* contexts under a mask.** One record per hart cannot carry it. |
| ↳ | **⭐⭐ The contribution** | Extend RVVI at its documented assumption boundary → attach the third-party VIP **unforked** → 80 covergroups from Imperas' own DV plans running against a GPU. |
| 13 | **⭐ Three coverage layers, proven disjoint** | L1 (ISA, third-party) ∩ L2 (SIMT, ours) = ∅ — proven by the 4,581 vs 1,677 identical-bin-set experiment. Never blend them. |
| ↳ | **The honest denominator** | 83.14% with `*_reg_assign` excluded — and *why* that exclusion is a scope decision, with the EUR/EOTH split machine-gated so the two classes cannot be blurred. |
| 15 | **OBS-057** | Injected AXI errors → **166/166** assertion firings. The DUT has no error path. "We didn't test this" → "we tested this, here's what breaks." |
| 19 | **⭐ `simtgen`** ⟨added 2026-09-07⟩ | riscv-dv/Spike have no warp/mask concept, so a 10-seed sweep bought +0.06% toggle. An original from-scratch generator (after ruling out reusing an external fuzzer's inseparable generator) closes the divergence-depth and bank-conflict bins that seed volume alone never could. |

**The strongest single slide remains the R10 story (14)**, with OBS-029 (a green run can be vacuous) close behind — both are arguments about *verification maturity*, which outrank any coverage percentage.

---

# APPENDIX A — Numbers cheat sheet

| Claim | Exact figure |
|---|---|
| Coverage, primary config | **94.7% total, 98.1% cg bins (370/377), 50/50 runs** |
| Coverage, 2-cluster | **94.6% total, 95.8% cg bins (989/1032), 50/50 runs** |
| Coverage, L2/L3 bank | **93.2% total, 51/51 runs** |
| Lockstep matrix | **6 configs, all lane-exact, 0 mismatches / 0 orphans** |
| Largest lockstep run | 3,333 / 3,333 writebacks (2CL/2C/4W/4T) |
| Spike three-way audit | **11,076 / 11,076 writebacks, 0 mismatches** |
| Load-feed flagship | **138 → 0 residual over 5,432 retirements** |
| Load-feed boundaries | interrupt **116 → 7**; control-flow **95 → 15** |
| Load-compare filter | 429 false → **74 compared / 113 filtered / 0 false** |
| Largest end-state compare | **32,836 words**, byte-exact |
| R10 impact | **12 assertion firings → 0**; branch **95.1% → 94.5%** |
| R1 blast radius | **every one of 12 riscv-dv profiles** fired misaligned assertions (30–7,616/run) |
| Seed sweep | **90 distinct programs, all pass, +0.06% toggle only** |
| Toggle root cause | icache **22,730 missing bins = 26.4%** of the entire gap, one subtree |
| **L1 ISA coverage (third-party VIP)** | **429/516 bins = 83.14%**, 89.28% weighted, **78/80 covergroups real** |
| **L1 raw, before any exclusion** | 1,444/6,469 = 22.32% — `*_reg_assign` is **92% of that denominator** (5,951 bins) |
| **L1 structural-exclusion gate** | hits **1,444 → 1,444** (unchanged) — machine-verified, run fails otherwise |
| **L1/L2 disjointness proof** | lane-as-hart (**4,581** samples) vs lane-0-only (**1,677**) → **identical bin set** |
| **ISA map integrity** | **0 map misses / 0 word mismatches** on every run |
| **AXI error injection (OBS-057)** | **166/166** `RUNTIME_ASSERT` firings; **4** dormant SVA covers closed |
| **`simtgen` closures (isolated merge, not yet banked)** ⟨new⟩ | `cp_split_depth` 3/4→**4/4**; `cp_bank_conflict` 0/3→**3/3**; `cp_coalesce_kind`→**3/3** |
| **`lmem_bank_cg.conflict` fix (OBS-060)** ⟨new⟩ | was permanently 0; now `idle=70460, no_conflict=61, conflict=169` |
| **POCL/OpenCL second stimulus path** ⟨new⟩ | `saxpy` PASSED — instrs=41601, cycles=41711, IPC=0.997363 (independently re-run, identical) |
| **OBS-061 — config assumption found false** ⟨new⟩ | primary config confirmed **FLEN=64, MISA D-bit=1** (dynamic isolated-elaboration proof), not the assumed FLEN=32 — 4 scoping questions open |
| Env scale ⟨re-measured 2026-09-07⟩ | **88 files, 22,562 lines, 5 agents, 11 taps, 23 covergroups (+80 third-party), 60 observations** |

---

# APPENDIX B — ⚠ Fix before the interview

**Both papers contain a stale self-contradiction.** `vortex_uvm_paper.tex:1062` and `vortex_uvm_paper_short.tex:876` state:

> *"a base-ISA audit against Spike (which cannot execute the SIMT extensions) **is planned, not done**."*

**But it *is* done** — 11,076/11,076 writebacks, 0 mismatches, documented in `docs/A6_SPIKE_INDEPENDENCE_AUDIT.md` — and **your own roadmap item 7 in the same paper contradicts the bullet** ("*The scalar base-ISA axis **has** an independent cross-check*"). The architecture figure also already shows Spike as completed.

If an interviewer reads the limitations section and asks about independence, you would be caught disagreeing with your own paper. **One-line fix in both files.**

---

*Sources: `docs/paper/vortex_uvm_paper.tex` (§§ env, verdicts, lockstep, loadfeed, coverage, provenance, rtlfindings, limits, enhance, tapeout), `docs/RTL_OBSERVATIONS.md` (OBS-001…061), `docs/VERIFICATION_PLAN_v2.md` (53 feature areas, three-layer model, waivers), `docs/RISCVISACOV_STATUS.md` (L1 integration, coverpoint taxonomy), `docs/GENERATOR_SCOPING_DECISION.md` (why FuzzGPU's generator was not reused, and what `simtgen` took instead), `docs/PPT_HANDOVER_WHOLE_PROJECT_20260906.md`, `docs/INDUSTRIAL_TRANSFORMATION_PLAN.md`, `docs/A6_SPIKE_INDEPENDENCE_AUDIT.md`, `docs/COVERAGE_MAX_20260816.md`, `Vortex/sim/uvmsim/scripts/simtgen/`, and the live environment at `Vortex/sim/uvmsim/`.*

*Revision 2026-09-07: all counts re-derived from the working tree (**88 SV/SVH files, 22,562 lines**; 23 covergroups; 11 taps; 56 observations) rather than carried forward from the 2026-08-25 text. Coverage banks cited by directory name in §7.4. Original repo state at first compilation: `Vortex-UVM-GP` @ `e7d30ab`, RTL submodule `vortex-uvm-gp-rtl` @ `3bffd16`; current work is on outer branch `feat/riscvisacov-coverage`, submodule branch `fft-poc`.*

*Revision 2026-09-07 (second pass, same day): added Part III-C (`simtgen`, an original SIMT-aware stimulus generator, both axes) and its POCL/OpenCL companion validation; added §7.5 (OBS-060, the `lmem_bank_cg.conflict` probe defect and its fix); added OBS-061 (FLEN=64/D-extension found elaborated at the primary config, confirmed dynamically — open scoping item) to Part X; added the OBS-058 external-corroboration note to §8.2; observation count updated 56→60 (`OBS-001…061`).*
