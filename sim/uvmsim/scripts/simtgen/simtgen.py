#!/usr/bin/env python3
"""simtgen.py — entry point for the from-scratch SIMT-aware random program
generator (Option B, docs/GENERATOR_SCOPING_DECISION.md). Day 1 of the S1
item: only the `divergence` axis (gen_divergence.py) is wired up.

Usage:
    python3 simtgen.py --seed N --out <kernel-dir> [--name NAME] [--axis divergence]

Emits <out>/main.cpp and <out>/Makefile, following the exact structure of
Vortex/tests/kernel/isacov_fill and .../multicore_isa (read before writing
this tool) so the existing `make sim TEST=kernel_launch_test
PROGRAM_NAME=<name> ...` flow picks it up completely unmodified — that
acceptance was proven for a hand-written kernel in Part A of the S1 day-1
task before any of this generation logic was written.

DETERMINISM (constraint 6): the ONLY randomness source used anywhere in this
tool is the single `random.Random(seed)` instance created in `main()` below
and threaded through to gen_divergence.generate(). No module here ever
touches the `random` module's global functions, wall-clock time, or
iterates a dict/set whose order depends on insertion history across runs.
Verify with: run twice at the same seed, diff the outputs (see
run_seeds.sh / the day-1 report for the executed proof).
"""

from __future__ import annotations
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_divergence  # noqa: E402
import gen_memory  # noqa: E402
import gen_barrier  # noqa: E402
import gen_vote_shfl  # noqa: E402
from knobs import DEFAULT_DIVERGENCE_KNOBS  # noqa: E402
from gen_memory import DEFAULT_MEMORY_KNOBS  # noqa: E402
from gen_barrier import DEFAULT_BARRIER_KNOBS  # noqa: E402
from gen_vote_shfl import DEFAULT_VOTE_SHFL_KNOBS  # noqa: E402

_TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")


def _write_kernel(out_dir: str, name: str, main_cpp_text: str) -> None:
    os.makedirs(out_dir, exist_ok=True)

    with open(os.path.join(out_dir, "main.cpp"), "w") as f:
        f.write(main_cpp_text)

    with open(os.path.join(_TEMPLATE_DIR, "Makefile.tmpl")) as f:
        makefile_tmpl = f.read()
    with open(os.path.join(out_dir, "Makefile"), "w") as f:
        f.write(makefile_tmpl.format(name=name))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--out", required=True, help="output kernel directory, e.g. "
                     "Vortex/tests/kernel/simtgen_s001")
    ap.add_argument("--name", default=None, help="PROJECT name; defaults to "
                     "basename(--out)")
    ap.add_argument("--axis", default="divergence",
                     choices=["divergence", "memory", "barrier", "vote_shfl"],
                     help="'divergence' (S1), 'memory' (S2), 'barrier' (S3, W4) "
                          "or 'vote_shfl' (S4, W4)")
    args = ap.parse_args()

    name = args.name or os.path.basename(os.path.normpath(args.out))

    # Constraint 6: ONE RNG instance, seeded, threaded through everything.
    rng = random.Random(args.seed)

    if args.axis == "divergence":
        src = gen_divergence.generate(rng, name=name, seed=args.seed,
                                       knobs=DEFAULT_DIVERGENCE_KNOBS)
    elif args.axis == "memory":
        src = gen_memory.generate(rng, name=name, seed=args.seed,
                                   knobs=DEFAULT_MEMORY_KNOBS)
    elif args.axis == "barrier":
        src = gen_barrier.generate(rng, name=name, seed=args.seed,
                                    knobs=DEFAULT_BARRIER_KNOBS)
    elif args.axis == "vote_shfl":
        src = gen_vote_shfl.generate(rng, name=name, seed=args.seed,
                                      knobs=DEFAULT_VOTE_SHFL_KNOBS)
    else:
        raise NotImplementedError(f"axis {args.axis!r} not implemented")

    _write_kernel(args.out, name, src)
    print(f"simtgen: wrote {args.out}/main.cpp + Makefile (axis={args.axis}, seed={args.seed}, name={name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
