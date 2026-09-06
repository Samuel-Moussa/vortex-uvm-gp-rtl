# Vortex UVM Verification Project — Full Status Brief
*Prepared 2026-08-25, for use as source material for a slide deck (Claude Design). Every number below is measured and banked in-repo, not projected.*

---

## 1. One-line pitch

**A complete, industrial-grade UVM verification environment for Vortex — an open-source RISC-V GPGPU — built solo, that achieves RVVI-style per-instruction lockstep against a stepping golden model for a SIMT architecture, which (to the project's knowledge) no prior public flow has done.** GPGPUs invert every assumption standard CPU verification makes: the DUT is a bus *master* that fetches its own stimulus (no sequence-item randomization path), and its SIMT execution model (warps, thread masks, divergence, barriers) sits entirely outside RVVI, Spike, or any existing scalar reference-model interface. This project builds that missing verification layer from scratch.

---

## 2. What Vortex is (context for the audience)

- Vortex: open-source RISC-V GPGPU (Georgia Tech, MICRO'21 / CARRV), executing **RV32IMAF + 6 custom SIMT instructions** (`wspawn`, `tmc`, `split`, `join`, `bar`, `tex`).
- Hierarchical topology: Clusters → Sockets → Cores → Warps → Threads, fully parametric.
- **Weakly coherent memory** by design (MICRO'21 §4.1.4) — caches only synchronize via explicit `fence`/flush, no MESI/snoop hardware exists (verified absent in RTL: zero `snoop|coherent|invalidate|MESI` hits across `hw/rtl/cache/*.sv`).
- Verification target config: **1 cluster / 1 core / 4 warps / 4 threads, AXI memory interface**, scaled up to 2-cluster/2-core for a second bank.

---

## 3. Project scope and role

- **Solo-built, full-stack verification effort**: environment architecture, agent/driver/monitor set, scoreboard, coverage model, constrained-random (riscv-dv) integration, directed test authorship, SVA protocol checking, and the C++/DPI golden-model integration layer. No hand-off boundaries — every layer above is one person's work.
- Packaged as an **upstream-shaped simulator backend**: lives at `Vortex/sim/uvmsim/`, alongside Vortex's own `sim/simx`, `sim/rtlsim`, `sim/opaesim`, `sim/xrtsim`, wired through the same `common.mk` convention, with an opt-in `make -C sim uvmsim` target — built to be *proposable back to the upstream project*, not a one-off grad artifact.
- Two IEEE-style papers written and typeset: a full version and a condensed ~8-page submission version (`docs/paper/vortex_uvm_paper.tex`, `vortex_uvm_paper_short.tex`), both compiled to PDF.

---

## 4. Why this is a hard problem (the "why nothing else does this" slide)

Standard RISC-V verification infrastructure fails outright for a GPGPU:

| Standard tool | Why it doesn't work here |
|---|---|
| Spike (reference ISS) | Purely scalar — cannot execute `wspawn`/`tmc`/`split`/`join`/`bar`/`tex`, has no concept of a warp or thread mask |
| RVVI (industry lockstep interface) | No transactor models per-lane thread masks or SIMT divergence state |
| Constrained-random sequence stimulus | The DUT is an **AXI bus master** that fetches its own instructions from memory — there is no sequence-item injection path to randomize; "stimulus" means *compiled kernel programs*, not bus transactions |

This project's answer: **SimX** (Vortex's own C++ functional emulator) is ~80% of an RVVI-shaped golden model already — it steps instruction-by-instruction and holds full SIMT architectural state — so it was integrated as the **primary** lockstep golden over a DPI-C bridge. **Spike is retained as a secondary, fully independent cross-check** on the base-ISA subset only, giving two independently-implemented models agreeing on the same execution — something neither model alone can prove.

---

## 5. Headline technical achievements (each independently verifiable in-repo)

### 5.1 Per-instruction lockstep for a SIMT architecture
- RVVI-style lockstep implemented against SimX over a DPI-C bridge — checks **every retired instruction**, not just end-of-program state.
- **Five original SIMT-specific stream-alignment rules** were required and documented — problems that simply do not exist in scalar-CPU lockstep: per-warp out-of-order commit, one load producing multiple overlapping-mask commit records, uuid-based flat core/warp identity encoding, load data not natively observable at the commit arbiter (closed with a new LSU probe), and more.
- **Independent three-way cross-check**: on `riscv_arithmetic_basic_test`, DUT / SimX / Spike all retired **exactly 11,076** architectural writebacks and agreed on every PC, destination register, and value — **0 mismatches**. This is a genuine independent-model agreement, not internal self-consistency.

### 5.2 Non-vacuity discipline — the checkers are proven to check something
- Every verdict class (result-compare, lockstep-compare, dropped-store detection) is backed by a **permanent fault-injection regression test** that must stay RED forever.
- Two live Gate-0 guards: `negative_result_test` (flips a bit in a written value) and `negative_dropped_store_test` (drops a store entirely) — both still fire correctly at the exact same faulted address (`0x800075d8`) after every later refactor of the scoreboard.
- This distinction — a green run proves nothing unless you've proven the checker can go red — is the single most senior-engineer-signaling result in the project.

### 5.3 Two-pass load-value feed — verifying racy, fenceless programs
- Vortex's weak-coherency model means multi-core programs without explicit fences have **architecturally undefined** memory-ordering outcomes — a naive lockstep would report false divergences on every such program.
- Built a two-pass load-value feed mechanism that renders these racy programs instruction-granularity verifiable anyway: **residual 0 over 5,432 retirements** on the flagship multi-core case.
- Precisely characterized the remaining **soundness boundary**: asynchronous interrupt timing and control-flow-steering races are explicitly scoped as unverifiable by this technique, and documented as such — not hidden.

### 5.4 Coverage — real numbers, structurally justified
- **Primary config (1 cluster/1 core/4 warps/4 threads): 94.72% total coverage, 98.14% functional covergroup bins (370/377), 50/50 programs passing, 0 failures.**
- **Scaled config (2 clusters/2 cores/4 warps/4 threads): 94.55% total, 95.44% covergroup bins (989/1032), 50/50 programs, 0 failures.**
- Every coverage exclusion is a **machine-generated, RTL-cited, config-generic structural waiver** (e.g., a config-aware script derives exclusion bounds from `VX_MEM_PORTS` / adapter buffer sizes) — none are hand-tuned to hit a target number. A blocking merge-time gate rejects any waiver that would move a previously-covered bin.
- Coverage model was **rewritten mid-project** after discovering that early flat crosspoint bins were firing on real traffic (a coverage-model bug, caught before it shipped as a false "0% reachable" claim).

### 5.5 Real defects found — in both the RTL and the reference models
Ten RTL findings (R1–R10) were catalogued with disposition (bug vs. hazard vs. quirk vs. characteristic vs. fixed):

| ID | Finding | Class | Disposition |
|---|---|---|---|
| R1 | JALR target LSB not cleared; odd PC propagates via AUIPC | **ISA-spec bug** | Needs RTL fix; stimulus sanitized around it |
| R2 | `STALL_TIMEOUT` uses `1**N ≡ 1` — watchdog never scales with config | Latent bug | Fixed; independently fixed upstream too |
| R3 | Misaligned access: no trap, silently retargeted/torn | Hazard | Expected per SW contract; gated |
| R4 | Core self-starts from reset; DCRs have no reset value | Hazard | Worked around via reset handshake |
| R5 | Per-warp out-of-order commit | Quirk | Handled in lockstep rules |
| R6 | One load → multiple overlapping-mask commit records | Quirk | Handled in lockstep rules |
| R7 | uuid encodes flat core id + warp id | Quirk | Exploited for per-core attribution |
| R8 | Load data not observable at commit arbiter | Observability gap | Closed with a new bound probe |
| R9 | Write path is fire-and-forget (`bready` tied high) | Characteristic | Cited as a coverage-exclusion basis |
| **R10** | **Reset relay leaves `reset_o` unknown (X) for one cycle** into every downstream module | **Bug (X-source)** | **Fixed; still open upstream** — found by *restoring* a project assertion that had been silenced during bring-up |

**R10 is the standout finding for an interview**: fixing it *reduced* measured branch coverage, because part of that coverage had (incorrectly) come from the unknown-reset state itself — a subtle, easy-to-miss regression that required understanding *why* a coverage number moving down was the correct outcome, not a problem to "fix back."

Reference-model findings (Findings II in the paper): a misaligned-instruction-fetch bug found in SimX **by the lockstep itself** (the golden model was wrong, not the DUT); abort-on-unknown as an unverifiability source; unpopulated retirement uuid; documented timing-class divergences and robustness gaps.

### 5.6 Configurability engineered as a first-class property, not an afterthought
- Elaboration-time asserts crosscheck testbench plusargs against the *actually-compiled* RTL parameters — a config mismatch aborts loudly at time 0 with a named diagnostic, rather than silently simulating the wrong topology.
- SimX's own C++ core objects are rebuilt per-configuration (proven from the build stamp, not assumed) so the golden model always matches the DUT's topology exactly.
- Coverage-exclusion generation, probe binding (commit probe, cache probe, DCR probe), and the lockstep rules all scale automatically across cluster/core/warp/thread counts — verified across a real config matrix (1C/1W, 4C/2W, 8C/8W/2T, 2CL/2C/4W/4T, etc.), never hand-special-cased per config.

### 5.7 A DCR register-access-layer with a genuinely novel read-back path
- The DCR (device control register) bus is **write-only in the RTL** — no frontdoor read exists. Built a `bind`-based passive backdoor probe into `VX_dcr_data` to supply the missing read side, making "did this configuration write actually land in the register?" a checked property for the first time in this environment.
- In the process, found and fixed **two testbench bugs** (a stale RAL mirror from non-RAL-issued writes; comparing against end-state instead of the write that produced an observation) where the *checker* was wrong and the RTL was right — and documented the general lesson: a firing checker is evidence to investigate, not proof of a DUT bug.

---

## 6. Engineering discipline / process signals (good for a "how I work" slide)

- **Every technical claim is grounded in `file:line` citations and reproducible sim output** — nothing in this project's status docs is asserted without a matching log or diff.
- **A single running RTL-observations log** (`docs/RTL_OBSERVATIONS.md`) captures every anomaly the moment it's found — bug, quirk, or enhancement — with evidence and disposition, never scattered or rewritten after the fact.
- **A measured negative result was kept, not hidden**: a 10-seed constrained-random sweep produced 90 distinct programs, all passing, with **zero coverage gain** — reported honestly as evidence that seed *volume* isn't the current bottleneck, correcting an earlier assumption that it was.
- **History-of-self-correction is visible and intentional**: multiple session logs record catching your own prior claim as wrong (a stale toggle-coverage attribution corrected from "write-through dcache" to "read-only icache" after re-deriving with a positive control; a 2CL pass-rate claim corrected after finding two testlist entries were byte-identical duplicate programs).
- **Token/cost discipline as an engineering constraint**: measured actual LLM-assisted-development spend from raw session logs (cache-read economics, not naive token counts) and adjusted workflow accordingly — evidence of treating even the *tooling* empirically.

---

## 7. Honest current limitations (own these proactively — they read as maturity, not gaps)

- **SIMT has no independent (second-implementation) reference model** — Spike's cross-check is scoped to base-ISA/warp0/lane0 only; there is currently no way to independently verify the SIMT-specific instructions two different ways. Documented as explicit future work, not glossed over.
- **2-cluster (2CL) coverage re-bank is not yet closed** — blocked on core-gating fixes for riscv-dv and one directed test at ≥2 cores (their generated programs are architecturally single-hart-defined; running them unmodified across independent cores is a stimulus bug, not a DUT bug, and was root-caused before being fixed).
- **Soundness boundary is explicit, not implicit**: asynchronous interrupt timing and control-flow-steering races are stated as **out of scope** for the current lockstep technique, with the mechanism for why written down.
- **L2/L3 cache hierarchy coverage deferred** — no kernel exercises it yet; it elaborates and builds cleanly but is Future Work as its own coverage bank.
- **Seed volume is directed-testing-in-a-CRV-costume today** — seed control and reproducibility are solved; running thousands of seeds (true constrained-random breadth) has not been attempted, and one measured sweep suggests diminishing returns without new kernel diversity first.

---

## 8. Suggested narrative arc for the deck

1. **The problem**: GPGPU verification breaks every standard RISC-V tool's assumptions (bus master, no reference model, no lockstep interface for SIMT).
2. **The approach**: repurpose Vortex's own functional emulator as an RVVI-shaped golden model; add Spike as an independent secondary check; solve the 5 SIMT-specific lockstep problems no scalar CPU has.
3. **The proof of rigor**: non-vacuity by permanent fault injection — every checker class proven to actually catch bugs, not just report green.
4. **The hard problem solved**: the two-pass load-value feed for racy fenceless programs, with an honestly stated soundness boundary.
5. **The numbers**: 94.7%/94.6% coverage across two configs, 0 failures, 100+ programs, all RTL-cited waivers.
6. **The findings**: R1–R10 real defects (headline: R10, the reset relay X-propagation bug that *reduced* coverage when fixed) plus reference-model bugs found by the lockstep itself.
7. **The discipline**: solo-built, upstream-packaged, two papers written, self-correcting process, honest open items.
8. **What's next**: SIMT-independent reference model, 2CL closure, L2/L3 coverage, seed-volume scaling — a credible roadmap, not a "done" claim.

---

*Source of truth for every number/citation above: `docs/INDUSTRIAL_TRANSFORMATION_PLAN.md`, `docs/paper/vortex_uvm_paper.tex`, `docs/RTL_OBSERVATIONS.md`, and the project `CLAUDE.md` session history, all in the `Samuel-Moussa/vortex-uvm-gp-rtl` / `Vortex-UVM-GP` repos as of 2026-08-21 (last commit `e7d30ab`).*
