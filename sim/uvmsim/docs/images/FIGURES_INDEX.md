# Figure index — sources, attribution, and how to use each one

Seven images, ready to attach to Claude Design. **Every third-party figure needs a visible
citation line on the slide** — the prompt already instructs Claude Design to add one, but check
that it did.

---

## Apache 2.0 — unambiguous to reuse

These ship with the Vortex repository itself under Apache 2.0, so reuse with attribution is
clean. **Prefer these where they fit.**

| File | What it shows | Use it on |
|---|---|---|
| `vortex_microarchitecture.png` | Official current Vortex microarchitecture | The "what Vortex is" slide, and as background for the environment-architecture slide |
| `cache_microarchitecture.png` | Official cache microarchitecture | The cache-coverage / MSHR discussion |

**Citation:** *Vortex GPGPU, Georgia Tech — Apache License 2.0.*

---

## Extracted from published papers — cite on the slide

Copyrighted by their publishers. Reproducing a figure with attribution in a technical talk is
normal academic practice; just make sure the citation is visible.

| File | Source | Why it earns a slide |
|---|---|---|
| `MICRO21_Fig4_vortex_microarchitecture.png` | MICRO'21 Fig. 4 | **The single most useful figure.** Shows Fetch/Decode/Issue/Execute/Commit, the **IPDOM stack**, wavefront scheduler, scoreboard, and the Cluster→L2→L3 hierarchy. Point at the **Commit** stage when you explain where the commit probe binds, at the **IPDOM stack** for divergence-depth coverage, and at the cluster/L2/L3 boxes for your config matrix. |
| `MICRO21_Fig8_simulation_stack.png` | MICRO'21 Fig. 8 | **Your best narrative device.** It shows Vortex's four simulator backends — OPAE, VLSIM, RTLSIM, SIMX — all over a common driver interface. Your `uvmsim` is a **fifth column added to this exact stack**. Show the figure, then show your version with the column added. |
| `MICRO21_Fig6_highbandwidth_cache_MSHR.png` | MICRO'21 Fig. 6 | Banked cache with **MSHR**, arbiters, and the **flush unit**. Use it for the MSHR-stall coverage bin, for arbiter-backpressure conditions, and to ground the weak-coherency point (flush *is* the coherency mechanism). |
| `MICRO21_Fig7_elastic_pipeline_handshake.png` | MICRO'21 Fig. 7 | `VX_ifetch_req_if`/`VX_ifetch_rsp_if` with valid/ready/data/**tag = (PC, wID)**. Good for the interface/protocol-assertion slide and for why tag width had to be derived from the RTL package rather than hardcoded. |
| `MULTICORE_Fig1_gpu_pipeline_extensions.png` | *Implementing Hardware Extensions for Multicore RISC-V GPUs*, Tine & Kim | Processor→Cluster→Core hierarchy with **DCRs**, HPM units, L2/L3 and the Command Processor. The clearest published picture of the **DCR** path — use it on the RAL slide. |

**Citations to put on the slides:**

- MICRO'21 — *B. Tine, K. P. Yalamarthy, F. Elsabbagh, H. Kim, "Vortex: Extending the RISC-V ISA for GPGPU and 3D-Graphics," MICRO-54, 2021.*
- Multicore extensions — *B. Tine, H. Kim, "Implementing Hardware Extensions for Multicore RISC-V GPUs," Georgia Institute of Technology.*

---

## Full-page renders (for finding more figures yourself)

Rendered at 150 DPI in `presentation_figures/pages/` in the outer repo — MICRO'21 (13 pages),
CARRV (15), multicore extensions (7). Browse them and crop anything else you want; they are
excluded from this directory to keep it light.

Figure→page map for MICRO'21:

| Page | Figures |
|---|---|
| p01 | Fig 1 — Vortex framework overview |
| p05 | **Fig 4 — microarchitecture** · Fig 5 — texture unit |
| p06 | **Fig 6 — high-bandwidth cache** · Fig 7 — elastic pipeline request |
| p07 | **Fig 8 — simulation stack** · Fig 9 — driver stack · Fig 10 — runtime · Fig 11 — binary generation |
| p09 | Fig 14 — IPC per core config · Fig 15–17 — area/GDS/power · Fig 18 — scaling · Fig 19 — multi-port caches |

**Page 5 also carries your weak-coherency citation in the body text** — *"Flush operations among
caches are provided as a means of providing weak coherent memory space"* (§4.1.4). That is the
sentence your entire load-value-feed argument rests on; consider quoting it directly on the
weak-coherency slide.

---

## Worth a look online (not bundled — go see them yourself)

You asked which presentations to look at. These are the ones worth your time before the meeting:

### Vortex project
- **Vortex homepage & publications** — https://vortex.cc.gatech.edu/ and
  https://vortex.cc.gatech.edu/publications/ — every paper plus the authors' own slide decks.
- **Vortex GitHub** — https://github.com/vortexgpgpu/vortex — the `docs/` tree has the
  architecture notes and the two Apache-2.0 diagrams you already have.
- **MICRO-54 talk (2021)** — the conference recording/slides for the paper above; the clearest
  walkthrough of the SIMT extensions (`wspawn`/`tmc`/`split`/`join`/`bar`) straight from the
  authors. Useful for making sure your terminology matches theirs.
- **Vortex tutorials at MICRO/HPCA** — the project has run tutorial sessions with public decks
  covering the microarchitecture and the simulation stack in more depth than the papers.

### Verification methodology (this is where your differentiators come from)
- **OpenHW core-v-verif** — https://github.com/openhwgroup/core-v-verif — the reference
  industrial UVM environment for RISC-V cores, and the origin of the `uvma_rvvi` pattern you
  followed. **Read their verification strategy docs before the meeting**; being able to say
  "I followed the core-v-verif RVVI monitor pattern rather than inventing a private format" is
  a strong, checkable claim.
- **RVVI specification** — https://github.com/riscv-verification/RVVI — the lockstep interface
  itself. Know what RVVI-VLG vs RVVI-API are, and be ready to say precisely which parts don't
  model per-lane thread masks.
- **riscv-dv** — https://github.com/chipsalliance/riscv-dv — the constrained-random generator
  in your flow.
- **Spike** — https://github.com/riscv-software-src/riscv-isa-sim — your independent ISS.
- **Siemens/Questa Verification Academy** — https://verificationacademy.com — the coverage
  closure, RAL and SVA material here is the vocabulary Egyptian DV interviewers (especially at
  Siemens EDA Cairo) will use. Skim the UVM RAL and functional-coverage tracks so your
  terminology lines up with theirs.

### Framing your own contribution
- **Vortex issue tracker / discussions** — worth checking whether R1 (JALR LSB), R2 (watchdog)
  and R10 (reset relay) have been reported since. If R10 is still open upstream, saying
  *"this defect is in the current release and I can show you the fix"* is a very strong moment.

---

## ⚠ Reminder about Claude Design and images

Published artifacts run under a strict content-security policy: **external image URLs will not
load.** Every figure must be embedded from a file you attach. That is why these are saved
locally rather than linked. If Claude Design produces a slide with a broken or placeholder
image, the fix is to attach the PNG, not to give it a URL.
