# Prompt for Claude Design — Vortex UVM presentation deck

> Copy everything below the line into Claude Design.
> **Attach:** `Vortex_UVM_Technical_Dossier.md`, plus any figure PNGs you want embedded.

---

Build me a technical presentation deck for a hardware verification project I built solo. The audience is a **semiconductor company's technical team interviewing me for a Digital Verification Engineer role**. They are practicing DV engineers — assume they know SystemVerilog, UVM, coverage, and assertions. Do not explain what a testbench is. Do explain what is *non-obvious* about verifying a GPGPU.

I am attaching `Vortex_UVM_Technical_Dossier.md`, which contains every measured number, RTL citation, and mechanism description. **Use it as the source of truth — do not invent figures.** If a number isn't in there, leave it out.

## What the project is

A complete UVM verification environment for **Vortex**, an open-source RISC-V GPGPU (RV32IMAF + 6 custom SIMT instructions: `wspawn`/`tmc`/`split`/`join`/`bar`/`tex`), verified on QuestaSim under Ubuntu/WSL2. It reaches **per-instruction lockstep against a stepping C++ golden model** — a checking depth normally seen only in commercial CPU flows, and to my knowledge not previously done for a SIMT architecture.

---

## Visual direction — READ FIRST

- **Light theme.** Clean white or very light neutral background, dark text. Engineering-document aesthetic, not a marketing deck. High contrast, readable when projected in a bright room.
- **Do not crowd slides.** One idea per slide. Generous whitespace. If a slide needs more than ~5 short bullets or ~40 words of body text, split it into two slides — I would rather have 32 clean slides than 20 dense ones.
- **Simple and straightforward.** Short declarative lines. No paragraphs on slides — detail goes in speaker notes.
- **Diagrams over bullet lists** wherever a mechanism is being explained. Draw them as clean inline SVG, light theme, minimal color (one accent color plus greys).
- Monospace for code, signal names, and file paths.
- Numbers should be visually prominent — they are the evidence. Use large-figure stat tiles rather than burying results in sentences.
- Every slide gets **speaker notes**: what I say out loud, plus the one question a sharp interviewer is likely to ask about that slide.

### Figures and images
Any image must be embedded from a file I attach — external URLs will not load. Where I attach the official Vortex architecture diagrams (`vortex_microarchitecture.png`, `cache_microarchitecture.png`, Apache 2.0), use them on the architecture/background slides **with a visible citation line** (e.g. *"Vortex GPGPU, Tine et al., Georgia Tech — Apache 2.0"*). If I attach figures extracted from the Vortex publications (MICRO'21, CARRV), cite them the same way beneath the figure. Where I have not supplied an image, draw your own clean SVG diagram rather than leaving a placeholder.

---

## Tone and depth

- **Technical with real depth, but do not drown in minutiae.** Every slide should teach a practicing DV engineer something they could use. Prefer *one mechanism explained properly* over five bullets of jargon.
- **Show the reasoning, not just the result.** "We hit 94.7% coverage" is weak. "Questa's total is the unweighted mean of 7 categories, so the *lowest* category is the biggest lever — which is why Directives (16 bins) got attacked before Toggle (425k bins)" is strong.
- No filler, no marketing adjectives, no "revolutionary/cutting-edge."

## ⚠ Framing rule

**Present the final, working state of the environment.** This is a portfolio of what I built and what it does *now*.

- **Do include** defects found *in the design under verification and in the reference model* — those are findings, and they are the strongest evidence the flow works.
- **Do NOT include** any narrative about mistakes in my own testbench that I later fixed — no "I initially got X wrong," no false-error stories, no coverage-model rework history. Those are in the dossier for my own preparation only.
- The dossier's R10 finding **is a design defect, not my mistake** — keep it, framed as: *a project assertion had been suppressed during bring-up; restoring it exposed a real RTL reset bug, now fixed, with the assertions running armed and silent.* Frame it forward, as a finding and a fix.

---

## MUST-COVER TOPICS — each of these needs its own slide (or two)

These are the techniques I most want the interviewers to see. **Do not compress or merge them away.**

1. **Two golden reference models, with deliberately different roles.** SimX (C++ functional emulator, SIMT-capable, stepped live over DPI-C) is the *primary* model and gives checking **depth**; Spike (independent scalar ISS, offline on an exported trace) gives **independence**. SimX is co-designed with the RTL and therefore not independent; Spike cannot execute SIMT. Neither substitutes for the other — say so explicitly. Show the three-way agreement result.

2. **Per-instruction lockstep** — the architecture: DUT probe stream vs. model retirement stream, aligned per (core, warp), compared per active SIMT lane on PC / destination register / value, with a four-way outcome taxonomy (matched / field mismatch / data mismatch / orphan) and drain-empty checks on both sides.

3. **The five SIMT stream-alignment rules** — the intellectual centerpiece, worth **two slides**. Retire order ≠ program order; the model's uuid can't be a cross-key (and how the RTL's own uuid encoding was exploited for multi-core attribution with zero RTL change); one instruction ≠ one retirement record (mask-union aggregation); load data needs its own tap *and* a soundness filter; performance-counter CSRs are model-divergent by definition.

4. **RVVI** — the industry lockstep interface. Cover why it does not transfer to SIMT out of the box (no transactor models per-lane thread masks or divergence state), and how the environment publishes an RVVI-style merged retirement stream through a UVM analysis port, deliberately following the OpenHW core-v-verif `uvma_rvvi` pattern rather than inventing a private format.

5. **The passive probe layer** — its own slide. Commit probe on every core's retire arbiter; LSU writeback probe for true per-lane load values; DCR probe; cache probes; scheduler and instruction-class probes. Two principles to state clearly: **all white-box visibility is passive and never a checker** (probes give observability, scoreboards give verdicts), and **probes scale by `bind`, not path enumeration** — one bind statement covers 1 core or 8 cores with zero testbench edits. Also: capture is plusarg-gated and proven byte-identical when off, so the observability layer cannot perturb what it observes.

6. **RAL — register abstraction layer with a backdoor that did not exist.** The DCR configuration bus is **write-only in the RTL**, so a frontdoor read is impossible. A `bind`-based peek-only probe supplies the missing read side, making "did this configuration write actually land in the register?" a checked property for the first time. Built with a `uvm_reg_predictor` on the *monitor*, so checking covers all stimulus rather than only RAL-issued writes. Note the safety rule: the probe is **peek-only by construction** — a backdoor *write* would silently desynchronize the golden model.

7. **Config-awareness of the coverage model** — its own slide. Coverpoint bounds and exclusions are **derived from RTL parameters, not hardcoded**: a generator emits per-topology waivers programmatically, each with a `file:line` citation; bins are keyed to the configuration (e.g. the global-barrier path is excluded only at single-core where it is structurally unreachable, and kept at ≥2 cores); coverage banks are reported per-configuration and never blended, because merging across topologies is provably invalid.

8. **The two-pass load-value feed** — **two slides**: mechanism, then soundness + result. How to verify racy, fenceless multi-core programs that are architecturally undefined, and the three soundness properties that stop it from masking a real bug. Include the flagship result and the instruction-exact attribution example (the flow doesn't just detect a difference — it proves the *model* was wrong, naming instruction, PC, cluster, and both conflicting values).

9. **Non-vacuity discipline** — four permanent fault-injection guards that must stay RED forever. *"A verdict is only as good as its ability to go red."* Plus the four-class verdict taxonomy where UNVERIFIABLE is first-class and never silently converted into a pass. **This is the single technique I most want them to notice.**

10. **Role-inverted UVM architecture** — the DUT is a bus *master* that fetches its own stimulus, so agents become *responders* and stimulus is a compiled ELF rather than sequence items. Show how tests and programs are made orthogonal and composed at build level.

11. **Coverage closure discipline** — machine-generated RTL-cited structural exclusions; reachable-but-unhit left red; ceilings root-caused by experiment rather than asserted; a blocking merge-time gate that rejects any waiver which changes a covered count.

12. **Configurability with self-checks** — one compiled environment runs any topology from plusargs; elaboration asserts abort at time 0 if testbench parameters disagree with the compiled DUT; the C++ model is rebuilt per configuration and verified from its build stamp.

13. **Linux / tooling / automation control** — its own slide, this matters for the role. Full Ubuntu 22.04 / WSL2 flow; Makefile-driven, four sourced bash stages (`run.sh → prepare.sh → compile.sh → simulate.sh`); regression suite driver with automated coverage merge and an invariant gate; the config-aware exclusion generator; cross-language build orchestration (SystemVerilog/UVM + a C++ model compiled per-config into a DPI-C shared object); Python tooling for the independent-ISS trace audit; git with submodules for RTL provenance pinning; packaged as an upstream-style simulator backend peer to the project's own `sim/simx` and `sim/rtlsim`.

**For each of the above, add one line naming where else the technique transfers** — e.g. role inversion → any processor/DMA/self-directed master; the alignment rules → any out-of-order or multi-context lockstep; the load feed → any weakly-ordered multi-core; non-vacuity → every verification project. The reusability of these ideas is a point I want landed repeatedly.

---

## Skills-mapping slide

DV job specs in Egypt (Siemens EDA, Si-Vision, ICpedia, Valeo, and Synopsys/Mentor-adjacent houses) consistently ask for: **SystemVerilog + assertions, UVM reusable environments, functional & code coverage metrics, verification planning and testbench architecture, scripting (Python/Perl/Tcl/bash), QuestaSim/VCS, and version control.**

Include one clean two-column slide mapping each requirement to concrete project evidence — assertions → the AXI4 SVA layer plus elaboration-time parameter checks; UVM reuse → five agents, RAL, config-generic `bind` probes; coverage → three independently banked configurations with a documented closure methodology; scripting → the automation stack; QuestaSim → the entire flow. Keep it a mapping, not a wall of text.

---

## Structure — 25 to 35 slides

Use section-divider slides between parts; they cost nothing and keep the deck breathable.

**Part 1 — The problem (4–5 slides)**
Title · What Vortex is (use the official microarchitecture diagram) · Why GPGPU verification breaks standard CPU assumptions · Why Spike / RVVI / constrained-random stimulus don't transfer · The weak-coherency consequence

**Part 2 — The environment (6–7 slides)**
Two golden models and their roles · Environment architecture diagram · Role-inverted agents · The passive probe layer · RVVI stream publication · RAL + backdoor probe · Protocol assertion layer (AXI4 SVA + throttle/flood stress)

**Part 3 — Lockstep (5–6 slides)**
Lockstep architecture · The five alignment rules (2 slides) · Cross-configuration validation matrix · Three-way independent agreement with Spike · Scope limit: writeback-domain only

**Part 4 — The hard problem (4–5 slides)**
Racy fenceless programs: why they're undecidable · The two-pass feed mechanism · Why it can't mask a bug · Flagship result · Instruction-exact failure attribution · Where the method provably stops

**Part 5 — Rigor and results (5–6 slides)**
Non-vacuity: the four injection guards · Verdict taxonomy · Coverage closure discipline · Config-aware coverage model · Coverage results (three banks) · Configurability with self-checks

**Part 6 — Findings and close (5–6 slides)**
Design defects found (R1–R10 table) · R10 in detail · R1 in detail · Linux/automation control · Skills mapping · Roadmap: front-end work vs. back-end/ASIC signoff drawn as an explicit line · Summary

The roadmap slide matters: it shows I know what tape-out signoff actually requires (gate-level sim, STA, DFT, CDC, low-power, equivalence checking, post-silicon) and that I am not overselling front-end functional verification as silicon readiness.
