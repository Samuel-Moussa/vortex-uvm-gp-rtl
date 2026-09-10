# Prompt — annotate Figure 4 with the probe bind points

> Supply the clean, unannotated `MICRO21_Fig4_vortex_microarchitecture.png` with this prompt.

---

You are annotating an existing technical block diagram. **Do not redraw, restyle, or regenerate
the diagram itself.** Every existing box, arrow, label and colour must survive completely
unchanged and every existing text string must remain pixel-identical and legible. Your only job
is to draw a small number of **callout labels with leader lines on top of** the supplied image.

Add whitespace **below** the diagram if you need room for the callout boxes. Do not crop, scale,
or reflow the original artwork.

## Style for the annotations

- Thin (1–2 px) leader lines in a single accent colour — dark blue `#1F4E79` — with a small
  arrowhead at the diagram end.
- Callout label: white rounded rectangle, thin dark-blue border, dark grey text, small sans-serif.
- Leader lines must **not cross each other** and must **not pass over any existing text label**.
- Anchor each arrowhead precisely on the named block's border.

## The five callouts

Anchor each one on exactly the block named. The block names below appear as text inside the
supplied diagram.

1. **Anchor: the `Wavefront Scheduler` box** (inside the `Fetch` group, immediately to the right
   of `IPDOM Stack`).
   Label: **`scheduler probe` — divergence-stack depth, split/join, barriers**

2. **Anchor: the boundary between the `Issue` group and the `Execute` group** — the arrow leaving
   `Issue` toward `Execute`.
   Label: **`instruction probe` — per-unit instruction classes, thread masks**

3. **Anchor: the `LSU` box** (the lowest yellow box inside the `Execute` group).
   Label: **`LSU writeback probe` — true per-lane load values**

4. **Anchor: the `Writeback` box** (inside the `Commit` group on the far right).
   Label: **`commit probe` — every core's retire arbiter**

5. **Anchor: draw ONE leader line that branches to touch all four cache blocks** — `Instruction
   Cache` (pink, inside `Fetch`), `Data cache` (pink, inside `Execute`), `L2 Cache` and
   `L3 Cache` (pink, in the cluster diagram on the left).
   Label: **`cache probes` — hit/miss, MSHR stall, per-bank**

## Do not add

- Do **not** add a callout for a device-configuration-register (DCR) probe — the block it binds
  to is not present in this diagram.
- Do **not** label the `IPDOM Stack` as a bind point. It is the structure the scheduler probe
  *observes*; the probe attaches to the scheduler.
- Do not add any legend, title, logo, watermark, or extra decoration.

## Caption to place under the image

Small italic grey text, one line:

*B. Tine, K. P. Yalamarthy, F. Elsabbagh, H. Kim, "Vortex: Extending the RISC-V ISA for GPGPU and 3D-Graphics," MICRO-54, 2021 — Fig. 4, annotated.*

## Optional footer line

Centred, bold, dark blue, below the caption:

**One `bind` statement per probe. 1 core or 8 cores, zero testbench edits.**
