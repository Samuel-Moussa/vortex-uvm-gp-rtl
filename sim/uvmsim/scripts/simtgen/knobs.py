"""knobs.py — single place for the simtgen axis definitions and weights.

ORIGINALITY NOTE: axis NAMES below are informed by the published FuzzGPU
(USENIX Security 2026) knob taxonomy as summarized in
docs/GENERATOR_SCOPING_DECISION.md §5 (divergence / memory-access-pattern /
barrier-and-sync axes) — a category label is not copyrightable structure or
code. No FuzzGPU source was read or consulted while writing this file; every
data structure, weight, and generation algorithm here is original.

Only DIVERGENCE (S1) has real weights/params today. MEMORY and BARRIER are
declared as placeholders (NotImplementedError if selected) for day 2/3 of the
S1 item — see CLAUDE.md task instructions, Part B: "Do NOT implement
gen_memory/gen_barrier/gen_vote_shfl yet."
"""

from __future__ import annotations
from dataclasses import dataclass, field
from typing import Dict


# ---------------------------------------------------------------------------
# Axis registry. `weight` is only meaningful once >1 axis is implemented and
# simtgen.py starts mixing axes per program; for S1 (divergence-only) it is
# unused but kept here as the documented single source of axis metadata.
# ---------------------------------------------------------------------------
AXES: Dict[str, dict] = {
    "divergence": {
        "weight": 1.0,
        "implemented": True,
        "module": "gen_divergence",
        "entry": "generate",
    },
    "memory": {
        "weight": 1.0,
        "implemented": True,
        "module": "gen_memory",
        "entry": "generate",
    },
    "barrier": {
        "weight": 1.0,
        "implemented": True,
        "module": "gen_barrier",
        "entry": "generate",
    },
    "vote_shfl": {
        "weight": 1.0,
        "implemented": True,
        "module": "gen_vote_shfl",
        "entry": "generate",
    },
}


@dataclass(frozen=True)
class DivergenceKnobs:
    """Parameters for gen_divergence.py (S1).

    max_depth: bound on nested-if divergence depth. Vortex's IPDOM
      reconvergence stack is DV_STACK_SIZE = NUM_THREADS-1 (RTL-derived, see
      Vortex/hw/rtl/VX_gpu_pkg.sv:53: `localparam DV_STACK_SIZE =
      \\`UP(\\`NUM_THREADS-1)`). For the project's primary/default config
      (THREADS=4) that is depth 3 — VERIFIED against the RTL source, not
      guessed. simtgen does not currently receive the target THREADS count at
      generation time (kernels size their own grid device-side at runtime,
      per OBS-028/constraint 3), so max_depth defaults to the depth-3 bound
      for the default config and is deliberately NOT raised above it — a
      generated program with more live nested divergence levels than the
      hardware's reconvergence stack supports for THREADS=4 would need a
      wider config to even be meaningful, which is out of scope for day 1.
    min_depth: shallowest tree to still call this "divergence" stimulus.
    branch_uniform_prob: probability a given branch condition is warp-uniform
      (i & 0 style — same outcome for every thread) rather than
      thread-divergent (i & 1 style). Both are useful: uniform proves the
      compiler doesn't force a split when it doesn't need one; divergent
      drives real split/join.
    max_live_values: bound on live scalar locals threaded through the tree,
      per HARD CONSTRAINT 5 (measured spill/spawn-join-deadlock risk above
      ~12-16 live values in this project). Kept conservative at 8.
    """
    max_depth: int = 3
    min_depth: int = 1
    branch_uniform_prob: float = 0.35
    max_live_values: int = 8

    # --- OBS-059 fix: bias generation toward the LINEAR THREAD-PEELING shape
    # that is the ONLY way to nest NUM_THREADS-1 real divergent splits before
    # the active set collapses to one thread (see vx_sched_probe.sv:80-86 and
    # gen_divergence.py's _build_peel_tree() docstring for the RTL citation).
    # Independent random bitmask conditions at every tree level (the pre-fix
    # `_build_tree` path, still used the rest of the time -- kept unchanged)
    # essentially never reproduces this exact shape by chance: confirmed
    # empirically at 0/50 seeds (OBS-059).
    peel_bias_prob: float = 0.5   # fraction of generated programs that use
                                   # the deterministic peel-chain builder
                                   # instead of the fully-random tree.
    peel_levels: int = 3          # NUM_THREADS-1 for the project's primary
                                   # config (THREADS=4) -- see VX_gpu_pkg.sv:53
                                   # DV_STACK_SIZE. Degrades gracefully (dead
                                   # `if(tid != k)` arms, no crash) on a
                                   # narrower config; stays within the
                                   # reachable range and never overflows the
                                   # IPDOM stack on a wider one.
    peel_terminal_split: bool = True  # append one more split AFTER the last
                                   # peel, purely to sample cp_split_depth
                                   # while the stack is already full (d[3] at
                                   # THREADS=4) -- always non-divergent by
                                   # construction (<=1 thread active there),
                                   # so it can never trigger the RTL's
                                   # "writing to a full stack" assertion.


DEFAULT_DIVERGENCE_KNOBS = DivergenceKnobs()


@dataclass(frozen=True)
class BarrierKnobs:
    """Parameters for gen_barrier.py (S3, W4).

    Deadlock-safe by construction, matching the proven `bar_masks` kernel
    (Vortex/tests/kernel/bar_masks/main.cpp): exactly ONE warp is spawned
    (grid == threads-per-warp) and every `vx_barrier` call uses num_warps==1,
    so a barrier is always satisfied by this warp's own arrival. Neither
    max_nt nor the num_warps invariant is varied per seed -- only the peel
    depth, thresholds, barrier ids and per-level literals are (see
    gen_barrier.py's module docstring for why num_warps must stay fixed).

    max_nt: static buffer bound for in_buf/out_buf, mirrors bar_masks'
      MAXNT=32 (a generous upper bound on any THREADS-per-warp this project
      builds with; the emitted main() clamps to the real vx_num_threads()
      at runtime regardless, same convention as every other kernel here).
    min_peel_depth/max_peel_depth: how many nested `if (tid < threshold)`
      barrier levels to emit, in addition to the always-present uniform
      (all-active) barrier at the top. Kept well under max_nt-1 so
      rng.sample() (sampling without replacement, no repeated thresholds)
      never needs more distinct values than [1, max_nt-1] offers.
    """
    max_nt: int = 32
    min_peel_depth: int = 1
    max_peel_depth: int = 3


DEFAULT_BARRIER_KNOBS = BarrierKnobs()


@dataclass(frozen=True)
class VoteShflKnobs:
    """Parameters for gen_vote_shfl.py (S4, W4).

    All 8 VOTE/SHFL ops (vx_vote_all/any/uni/ballot, vx_shfl_up/down/bfly/idx)
    are called in every generated program -- op-coverage (cp_vote_shfl_op)
    does not depend on active-mask state (no cross exists gating it on
    cp_active_threads, confirmed by reading tb/vx_instr_probe.sv before
    writing this generator), so per-seed variety comes from the PREDICATE
    shapes fed to the vote ops and the shift amount (bval) fed to the shuffle
    ops, plus which lanes are peeled out before the calls execute (so VOTE
    genuinely sees varying active-thread-count contexts across seeds, per
    the axis's original "under divergent masks" intent, even though the
    coverpoint itself does not require it).

    mask is deliberately NEVER varied (fixed at 0, "single subgroup spanning
    the whole warp" -- the exact, already-validated convention the existing
    `vote_shfl` kernel uses, Vortex/tests/kernel/vote_shfl/main.cpp:52).
    Varying it changes shuffle sub-group partitioning in a way this project
    has not independently verified is safe/meaningful; scoped out rather
    than guessed, same discipline as every other waiver/scope decision in
    this codebase.

    max_bval: shuffle shift amount is drawn from [0, max_bval] at Python
      generation time, but NUM_THREADS (and therefore the RTL-meaningful
      clamp = NUM_THREADS-1) is only known at kernel COMPILE time
      (VX_config.h) -- so the emitted C code itself does `bval % NUM_THREADS`
      before every shuffle call, exactly like the existing `vote_shfl`
      kernel's `clamp = NUM_THREADS - 1` pattern, rather than trusting this
      Python-side bound alone to stay in range for every build.
    """
    max_bval: int = 31


DEFAULT_VOTE_SHFL_KNOBS = VoteShflKnobs()
