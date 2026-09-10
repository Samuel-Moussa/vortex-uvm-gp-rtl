# Correction prompt — deck revision 2

> Paste into the same Claude Design conversation that produced the deck.
> If you have a Synopsys VIP / UVM-cookbook reference image, attach it with this.

---

Two corrections to the deck. Everything else stays as it is — please change only these two slides.

---

# CORRECTION 1 — Slide 8, the UVM environment architecture diagram

The current diagram is hard to read: too many crossing leader lines, and the layout does not follow
a recognised convention. Please redraw it in the **standard layered UVM architecture style** used
in vendor verification cookbooks (Synopsys VIP / UVM reference documentation).

## Style rules — follow these strictly

- **Strict layering, top to bottom.** Test at the top, then sequences, then the environment with
  its agents, then the interfaces, then the DUT at the bottom. Every reader of a UVM diagram
  expects this order.
- **Orthogonal routing only.** All connectors are horizontal or vertical with 90° corners. **No
  diagonal lines.** No line may cross another — if two connections would cross, route one around
  the outside of the block.
- **Containment, not arrows, for hierarchy.** An agent *contains* its driver, monitor and
  sequencer — draw them as nested boxes inside the agent's border. Do not draw arrows to show
  "belongs to".
- **Arrows are reserved for data flow only**, and each carries a small lowercase label
  (`seq_item`, `analysis`, `DPI-C`, `bind`).
- **Consistent, quiet colour coding** — light fills, dark thin borders, one hue per role:
  - active agents — light blue
  - passive components and probes — light grey, **dashed** border
  - scoreboards and coverage — light amber
  - reference models — light green
  - DUT — white with a heavier border
- **Uniform box sizes** within a layer. Align every box to a grid; equal gutters throughout.
- **Whitespace is required.** If the diagram feels dense, make the canvas larger — do not shrink
  the gaps.
- Monospace for component type names (`axi_driver`, `rvvi_monitor`), sans-serif for descriptive
  labels.

## The architecture to draw

**Layer 1 — Test**
`vortex_base_test` → derived tests (`kernel_launch_test`, `host_coverage_test`,
`random_instruction_stress_test`, the two negative tests)

**Layer 2 — Sequence layer**
`vortex_virtual_sequencer`, holding typed handles to the four agent sequencers. Above it, the
virtual sequences (`kernel_launch_vseq`, `host_coverage_vseq`, `random_instr_stress_vseq`).

**Layer 3 — Environment `vortex_env`**, containing five agents side by side:

| Agent | Label it | Contains |
|---|---|---|
| `host_agent` | **active** | sequencer · driver · monitor |
| `dcr_agent` | **active** | sequencer · driver · monitor |
| `axi_agent` | **active responder** | driver · monitor *(no sequencer connection)* |
| `mem_agent` | **active responder** | driver · monitor |
| `status_agent` | **passive** | monitor only |

Also inside the env, to one side:
- `vortex_scoreboard` — end-state, bidirectional
- `lockstep_scoreboard` — per-instruction, per-lane
- `vortex_coverage_collector`
- `rvvi_monitor`
- the **DCR RAL block** — `vortex_dcr_reg_block` + `vortex_dcr_adapter` + `uvm_reg_predictor` +
  `vortex_dcr_ral_checker`

**Layer 4 — Interfaces** (each carrying its SVA assertions; annotate the AXI one **"30 assertions
+ 16 cover properties"**):
`vortex_axi_if` · `vortex_mem_if` · `vortex_dcr_if` · `vortex_if` · `vortex_status_if`

**Layer 5 — DUT**
`Vortex GPGPU` — label it clearly **"AXI master — fetches its own stimulus"**.

**Right-hand column — reference models** (light green):
- `SimX` — primary golden model, connected to the environment by a **`DPI-C`**-labelled arrow,
  bidirectional (load / run / retirement records)
- `Spike` — secondary, **dashed** border, offline, marked *"base-ISA cross-check, warp0/lane0"*

**Probe layer** — a thin dashed grey band between the DUT and the interfaces, containing six small
dashed boxes labelled `commit` · `lsu` · `sched` · `instr` · `dcr` · `cache`. One dashed arrow
labelled `bind` from the band into the DUT, and one arrow from the band up to `rvvi_monitor`.
**Do not draw six separate arrows** — group them.

## Key relationships that must be visually obvious

1. The **AXI and memory agents point *into* the env from the DUT** — the DUT drives them, not the
   reverse. Make the arrowhead direction show this.
2. The **probe band is dashed throughout** — passive, never a checker.
3. **Two scoreboards, both fed from the reference model**, one from the memory model and one from
   the RVVI monitor.

---

# CORRECTION 2 — Slide 12, the probe bind points

The slide currently shows **three** probes. There are **six**. Please add the missing three and
correct one label.

Anchor each callout on the named block of the Vortex microarchitecture figure.

| # | Callout label | Anchor on |
|---|---|---|
| 1 | **`commit probe`** — every core's retire arbiter | the **Commit** stage box |
| 2 | **`LSU writeback probe`** — true per-lane load values | the **LSU** box inside **Execute** |
| 3 | **`scheduler probe`** — divergence-stack depth, split/join, barriers | the **Wavefront Scheduler** box |
| 4 | **`instruction probe`** — per-unit instruction classes, thread masks | the **Issue → Execute** boundary arrow |
| 5 | **`cache probes`** — hit/miss, MSHR stall, per bank | one line branching to **Instruction Cache**, **Data cache**, **L2 Cache**, **L3 Cache** |
| 6 | **`DCR probe`** — read path for a write-only register bus | **no block exists for this in the figure** — place it as a footnote line beneath the diagram, not as an arrow: *"a sixth probe binds to the device-configuration-register file, which this figure does not show."* |

## Two corrections to what is already there

- The divergence callout must anchor on the **Wavefront Scheduler**, **not** the `IPDOM Stack`.
  The probe binds to the scheduler; the IPDOM stack is the structure it *observes*. Do not label
  `IPDOM Stack` as a bind point.
- Callout #1 currently points at the inner `Writeback` box. Point it at the **Commit** stage
  boundary instead — the probe taps the commit *arbiter*, and the arbiter is the reason retire
  order differs from program order.

## Layout rules for this slide

- Six callouts is a lot. Use **three on the left, three on the right**, all leader lines
  orthogonal, **none crossing**.
- Keep the callout boxes small and uniform; put only the bold probe name and a short phrase in
  each.
- Keep the existing citation line under the figure.
- Keep the footer line: **One `bind` statement per probe. 1 core or 8 cores, zero testbench edits.**
