"""gen_divergence.py — S1: divergence-tree axis for simtgen.

Emits a Vortex device kernel whose body is a nested tree of C `if`/`else`
statements over thread-id-dependent (or warp-uniform) conditions, so clang
lowers real SIMT split/join control flow (VX_split_join / VX_ipdom_stack) —
never hand-assembled divergent branches (HARD CONSTRAINT 2 / OBS-056).

Original algorithm (no FuzzGPU code read or reused — see knobs.py header for
the originality note). The generation strategy:

  1. Build an abstract tree in `_build_tree()`: at each recursion level,
     decide (a) whether to stop (leaf) or branch further, gated so the
     overall depth lands somewhere in [min_depth, max_depth], and (b)
     whether the branch condition is warp-uniform or thread-divergent.
  2. Render the tree to C text in `_render()`: each branch is a real
     `if (...) { ... } else { ... }` over `tid`/`i`; each leaf adds a
     distinct literal to a running accumulator `r`, so the two arms are
     never byte-identical (a no-op if/else the compiler could fold away
     would defeat the point of divergence stimulus).

HARD CONSTRAINTS enforced here (cross-referenced to the task's numbered
list):
  1. RACE-FREE: the kernel writes only `out_buf[i]`, i's own slot — see
     _render_kernel(), no other array is touched.
  2. REAL C CONTROL FLOW: conditions and branches are plain C `if`/`else`;
     no inline asm anywhere in this module.
  3. DEVICE-DERIVED GRID: the emitted main() sizes the grid from
     vx_num_cores()*vx_num_warps()*vx_num_threads() at runtime — see
     _MAIN_TEMPLATE below, never a hardcoded total.
  4. NO SELF-CHECK: main() returns 0 unconditionally; SimX lockstep +
     end-state compare are the checker (see _MAIN_TEMPLATE — no reference
     recompute, no error-counting loop).
  5. BOUNDED LIVE VALUES: recursion depth is capped by
     knobs.max_depth (RTL-derived, see knobs.py), and each level
     introduces at most one new local (`t<depth>`), so live locals never
     exceed max_depth+2 (well under the ~12-16 spill-risk threshold).
  6. SEEDED/DETERMINISTIC: every random choice goes through the single
     `random.Random` instance passed in by the caller (`rng`); no other
     randomness source is touched anywhere in this file.
"""

from __future__ import annotations
from dataclasses import dataclass
from typing import List

from knobs import DivergenceKnobs, DEFAULT_DIVERGENCE_KNOBS


@dataclass
class _Node:
    is_leaf: bool
    depth: int
    uniform: bool = False           # only meaningful when not a leaf
    literal: int = 0                # leaf: constant added to r
    then_branch: "_Node" = None     # non-leaf
    else_branch: "_Node" = None     # non-leaf
    then_literal: int = 0           # non-leaf: extra constant per arm
    else_literal: int = 0
    condition: str = None           # non-leaf: pre-fixed condition text
                                     # (peel-tree only). None => _render()
                                     # falls back to _condition_expr()'s
                                     # random-mask behaviour, unchanged from
                                     # the original algorithm.


def _build_tree(rng, depth: int, knobs: DivergenceKnobs, literal_pool: List[int]) -> _Node:
    """Recursively build the divergence tree. `literal_pool` is a mutable
    counter list (single int) shared across the whole build so every leaf /
    branch-arm constant is distinct, making DUT-vs-golden divergence in the
    arithmetic path unambiguous in a waveform/trace if ever inspected."""

    def next_literal() -> int:
        literal_pool[0] += 1
        return literal_pool[0] * 7 + 3  # arbitrary distinguishing sequence

    # Stop condition: below min_depth we always continue; at/above
    # max_depth we always stop; in between, a coin flip (seeded) decides —
    # this is what makes different seeds produce trees of varying depth,
    # per the task's "varying depth 1 to <supported>" requirement.
    if depth >= knobs.max_depth:
        return _Node(is_leaf=True, depth=depth, literal=next_literal())
    if depth < knobs.min_depth:
        continue_branching = True
    else:
        continue_branching = rng.random() < 0.6

    if not continue_branching:
        return _Node(is_leaf=True, depth=depth, literal=next_literal())

    uniform = rng.random() < knobs.branch_uniform_prob
    node = _Node(
        is_leaf=False,
        depth=depth,
        uniform=uniform,
        then_literal=next_literal(),
        else_literal=next_literal(),
    )
    node.then_branch = _build_tree(rng, depth + 1, knobs, literal_pool)
    node.else_branch = _build_tree(rng, depth + 1, knobs, literal_pool)
    return node


def _build_peel_tree(rng, knobs: DivergenceKnobs, literal_pool: List[int]) -> _Node:
    """OBS-059 fix: deliberately construct a LINEAR THREAD-PEELING chain
    instead of an independent-random-mask tree.

    RTL grounding (read from the actual sources, not assumed):
      - `vx_sched_probe.sv`'s divergence-depth sample (`u_divergence.sample`,
        vx_sched_probe.sv:304-313) records `warp_ctl_if.dvstack_ptr` at the
        moment of EVERY split event -- that signal is
        `VX_split_join.sv:85 assign stack_ptr = ipdom_wr_ptr[stack_wid]`,
        i.e. the IPDOM stack's write pointer, sampled BEFORE that event's own
        push (if any). So a sample of depth==D means D real divergent pushes
        already happened and have not yet been popped.
      - `VX_split_join.sv:46-52`: a split only pushes when `split.is_dvg` is
        set (both `then_tmask` and `else_tmask` non-empty). `ipdom_d1 =
        {split.else_tmask, split.next_pc}` is what gets pushed and later
        popped to resume the ELSE arm; the THEN arm's PC continues executing
        immediately, unpopped. So nested splits INSIDE a `then` block push
        onto the stack on TOP of the still-open outer entry, while nested
        splits inside an `else` block only run after that entry has already
        been popped back off. => depth only accumulates along a chain of
        THEN arms (or, symmetrically, any single unbroken continuation path
        -- but `then` is the one this generator controls directly).
      - `VX_ipdom_stack.sv` is sized `DEPTH=DV_STACK_SIZE=NUM_THREADS-1`
        (`VX_gpu_pkg.sv:53`) and `full_r` asserts `RUNTIME_ASSERT` on a push
        while full (VX_ipdom_stack.sv:50) -- so the stack can hold AT MOST
        NUM_THREADS-1 concurrent real divergent splits, which forces each
        level's active set to shrink by AT LEAST one thread (a genuinely
        divergent split needs >=2 threads in both arms combined, and at
        THREADS=4 there are only 4 threads total to spend across 3 levels).
        The only shape that reaches all 3 levels is therefore "peel exactly
        one thread off, keep the rest, peel one more, ..." -- balanced
        splits (e.g. 4->2/2) exhaust the active set before the 3rd level.

    This builder peels thread ids 0, 1, 2, ... one at a time: `then` keeps
    "everyone except the peeled id" (continues recursing), `else` is a leaf
    holding just the peeled thread. After `knobs.peel_levels` real peels
    (=3 at THREADS=4, filling the stack to depth 3), it optionally appends
    ONE MORE split (`knobs.peel_terminal_split`) purely to generate a
    `split.valid` sample while the stack is already full -- that sample is
    what lands in `cp_split_depth`'s bin `d[peel_levels]` (d[3] at
    THREADS=4). That terminal split can only be non-divergent by
    construction (at most one thread is active there for the default
    config), so it can never overflow the stack or fire the RTL's
    "writing to a full stack" runtime assertion.
    """

    def next_literal() -> int:
        literal_pool[0] += 1
        return literal_pool[0] * 7 + 3

    def build_level(peel_id: int) -> _Node:
        if peel_id >= knobs.peel_levels:
            if knobs.peel_terminal_split:
                # Reuse the existing thread-divergent condition style (a
                # fresh random tid-mask) for the terminal probe split -- it
                # only needs to be a real tid-dependent branch, not any
                # specific value; whatever the actual active set is at this
                # point, the RTL will correctly report is_dvg accordingly.
                terminal_cond = _condition_expr(
                    _Node(is_leaf=False, depth=peel_id, uniform=False), rng
                )
                node = _Node(
                    is_leaf=False,
                    depth=peel_id,
                    uniform=False,
                    condition=terminal_cond,
                    then_literal=next_literal(),
                    else_literal=next_literal(),
                )
                node.then_branch = _Node(is_leaf=True, depth=peel_id + 1, literal=next_literal())
                node.else_branch = _Node(is_leaf=True, depth=peel_id + 1, literal=next_literal())
                return node
            return _Node(is_leaf=True, depth=peel_id, literal=next_literal())

        node = _Node(
            is_leaf=False,
            depth=peel_id,
            uniform=False,
            condition=f"(tid != {peel_id})",
            then_literal=next_literal(),
            else_literal=next_literal(),
        )
        node.then_branch = build_level(peel_id + 1)     # keep peeling
        node.else_branch = _Node(is_leaf=True, depth=peel_id + 1, literal=next_literal())  # the peeled thread
        return node

    return build_level(0)


def _condition_expr(node: _Node, rng) -> str:
    """A condition over `tid` (divergent, thread-index within the spawn
    grid modulo the local var `nt`) or `wid` (warp-uniform: same value for
    every lane in a warp). Both are pure functions of (i, nt) computed
    identically on... nothing -- there is no host reference (constraint 4);
    the expression just has to be real, cheap, and either uniform or
    divergent as declared.
    """
    if node.uniform:
        # wid = i / nt is constant across all lanes of one warp -> every
        # thread in the warp evaluates this identically -> no split.
        mask = rng.choice([1, 2, 3])
        return f"((wid & {mask}) == 0)"
    else:
        # tid = i % nt varies per lane within a warp -> genuine divergence.
        mask = rng.choice([1, 3, 7])
        cmp = rng.choice(["==", "!="])
        val = rng.randint(0, mask)
        return f"((tid & {mask}) {cmp} {val})"


def _render(node: _Node, rng, out: List[str], indent: str) -> None:
    if node.is_leaf:
        out.append(f"{indent}r += {node.literal};")
        return
    cond = node.condition if node.condition is not None else _condition_expr(node, rng)
    out.append(f"{indent}if {cond} {{")
    out.append(f"{indent}  r += {node.then_literal};")
    _render(node.then_branch, rng, out, indent + "  ")
    out.append(f"{indent}}} else {{")
    out.append(f"{indent}  r += {node.else_literal};")
    _render(node.else_branch, rng, out, indent + "  ")
    out.append(f"{indent}}}")


_MAIN_TEMPLATE = """\
// {name} — simtgen-generated (S1 divergence axis). Seed: {seed}.
// Generated by scripts/simtgen/gen_divergence.py — original tool, no
// FuzzGPU code vendored or transliterated (see knobs.py header).
//
// Emits nested C if/else divergence (never hand-asm branches, OBS-056),
// device-derived grid (OBS-028), race-free per-thread writes only, and no
// self-check -- SimX lockstep + end-state compare do the checking
// (S1 handover: "the generator's only job is to produce interesting
// programs").

#include <vx_intrinsics.h>
#include <vx_spawn.h>

#define MAX_TOTAL 128

volatile int out_buf[MAX_TOTAL];

typedef struct {{ int *out; int nt; }} {name}_args_t;

static inline int {name}_body(int i, int nt) {{
  int tid = i % nt;
  int wid = i / nt;
  // OBS-059 addendum: `r` MUST be volatile. Measured fact, not a style
  // choice -- with a plain `int r`, LLVM recognizes chains of mutually
  // exclusive small-constant equality tests (a peel chain's `tid != 0`,
  // `tid != 1`, `tid != 2`, ...) as a classic range-test/jump-table
  // pattern and COLLAPSES the whole nested if/else structure into ONE
  // real branch + a precomputed literal lookup table (confirmed by
  // reading the compiled .dump: a 4-level nested if became exactly one
  // `vx_split_n`/`vx_join` pair plus a table load). Every `r += literal`
  // here is a real accumulation with no other side effect, so nothing
  // stops that optimization -- `volatile` forces each accumulation
  // through memory in program order, which the compiler cannot
  // speculate or fold across control-flow paths, so the nested
  // conditions survive as real per-level SIMT splits.
  volatile int r = i * 3 + 1;
{body}
  return r;
}}

void {name}_kernel({name}_args_t *__UNIFORM__ args) {{
  int i = blockIdx.x;
  args->out[i] = {name}_body(i, args->nt);
}}

int main() {{
  int nt = vx_num_threads();
  if (nt < 1) nt = 1;

  {name}_args_t args;
  args.out = (int *)out_buf;
  args.nt = nt;

  // Device-derived grid (constraint 3 / OBS-028) -- never hardcoded.
  uint32_t total = (uint32_t)vx_num_cores() * vx_num_warps() * vx_num_threads();
  if (total > MAX_TOTAL) total = MAX_TOTAL;
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb){name}_kernel, &args);

  // No self-check (constraint 4): SimX lockstep + end-state compare verify.
  return 0;
}}
"""


def generate(rng, name: str = "simtgen_div", seed=None, knobs: DivergenceKnobs = None) -> str:
    """Generate one divergence-axis kernel's main.cpp source text.

    `rng` MUST be a `random.Random` instance owned by the caller (constraint
    6: one seeded RNG threaded through everything, never the `random`
    module's global state). `seed` is only used cosmetically, in the emitted
    file's header comment.
    """
    if knobs is None:
        knobs = DEFAULT_DIVERGENCE_KNOBS

    literal_pool = [0]
    # OBS-059 fix: bias a fraction of programs toward the deterministic
    # linear thread-peeling shape (_build_peel_tree) needed to reach
    # cp_split_depth's max bin; the rest keep using the original
    # independent-random-mask tree unchanged (_build_tree).
    if rng.random() < knobs.peel_bias_prob:
        tree = _build_peel_tree(rng, knobs, literal_pool)
    else:
        tree = _build_tree(rng, 0, knobs, literal_pool)

    body_lines: List[str] = []
    _render(tree, rng, body_lines, "  ")
    body = "\n".join(body_lines)

    return _MAIN_TEMPLATE.format(name=name, seed=seed, body=body)
