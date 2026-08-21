# uvmsim — QuestaSim/UVM verification backend

A UVM verification environment for Vortex, packaged as a simulator backend
alongside [`sim/simx`](../simx), [`sim/rtlsim`](../rtlsim), [`sim/opaesim`](../opaesim)
and [`sim/xrtsim`](../xrtsim). Unlike those, it requires a licensed QuestaSim
install, so it is not part of `sim`'s default `all` target — build/run it
explicitly (`make -C sim uvmsim`, or from inside this directory).

## Method

Black-box **end-state equivalence**: the DUT and the **SimX** C++ golden model
run the same program from the same configuration; the scoreboard compares the
final memory, console, and exit state over a DPI-C bridge.

## Prerequisites

- **QuestaSim 2021.2+** (the flow auto-detects `vsim`).
- A **RISC-V toolchain** — `riscv{32,64}-unknown-elf` GCC/LLVM 14.
- A **C++17 compiler** to build the SimX model into `simx_model.so`.
- Host: Ubuntu 22.04 (validated under WSL2).
- The repo configured (`./configure` at the Vortex root) — this directory's
  `Makefile` includes `../common.mk`, same as every other `sim/*` backend, and
  needs the resulting `config.mk` for `VORTEX_HOME`.

## Running

All flows go through the `Makefile`, which drives four sourced scripts —
`run.sh → prepare.sh → compile.sh → simulate.sh`:

```bash
# Full flow: build SimX DPI lib, compile RTL + UVM, simulate.
make sim TEST=kernel_launch_test PROGRAM_NAME=vecadd_lite TIMEOUT=200000

# Re-run without recompiling the RTL.
make sim-only TEST=kernel_launch_test PROGRAM_NAME=vecadd_lite

# Waveform debug in the Questa GUI.
make gui TEST=kernel_launch_test PROGRAM_NAME=vecadd_lite

# Full regression suite + coverage merge.
bash scripts/run_suite.sh

make help          # all targets and flags
```

`PROGRAM_NAME=<kernel>` resolves an ELF under `$(VORTEX_HOME)/tests/kernel/<name>/`
(`VORTEX_HOME` comes from `../common.mk` / `config.mk`, not a hardcoded relative
path). `riscv_*` programs are generated and compiled through the riscv-dv
pipeline in `prepare.sh` (see [`docs/RISCV_DV_GUIDE.md`](../../../docs/RISCV_DV_GUIDE.md)
in the outer verification-project repo).

### Configuration

One parameter set drives the RTL (`+define+`), SimX (`-D` macros, recompiled per
config), and the testbench (runtime `+plusargs`). Elaboration asserts abort at
time 0 if the testbench topology disagrees with the compiled DUT.

```bash
make sim TEST=kernel_launch_test PROGRAM_NAME=vecadd_lite \
         CLUSTERS=2 CORES=2 WARPS=4 THREADS=4 INTERFACE=axi TIMEOUT=200000
```

### Keeping coverage banks / run results outside this tree

By default `results/` and `cov/` are created self-contained under this
directory (gitignored — see `.gitignore`). A checkout that wants to keep
its coverage banks / run history elsewhere (e.g. alongside a separate
verification-project repo) can point at it via a gitignored `local.mk`:

```make
export VORTEX_UVM_COV_DIR     := /path/to/cov
export VORTEX_UVM_RESULTS_DIR := /path/to/results
```

## Structure

```
sim/uvmsim/
├── tb/                 vortex_tb_top.sv, interfaces, binds, elaboration asserts
├── uvm_env/
│   ├── agents/         axi · mem · dcr · host · status
│   ├── ref_model/      SimX DPI bridge (simx_dpi.cpp, simx_pkg.sv)
│   ├── vortex_scoreboard.svh         end-state equivalence vs SimX
│   ├── vortex_coverage_collector.svh
│   └── vortex_config.sv              config derived from RTL params
├── uvm_tests/          test library (extend vortex_base_test)
├── scripts/            run.sh, prepare.sh, compile.sh, simulate.sh, run_suite.sh,
│                       gen_coverage_exclude.sh, merge_coverage.sh
├── flists/             vortex_rtl.flist, uvm_env.flist, cvfpu.flist
└── docs/               testbench-specific writeups (FILE_TREE, GLIBCXX fix, …)
```

Coverage banks, run results, and the project-level verification plan/reports
live in the outer verification-project repo, not in this tree (see
`VORTEX_UVM_COV_DIR` / `VORTEX_UVM_RESULTS_DIR` above).

## Extending

**Add a test** — create a file in `uvm_tests/` extending `vortex_base_test`,
build/start a sequence in `run_phase`, and register it in the regression list.

**Add a sequence** — create a file under `uvm_env/sequences/` extending
`vortex_base_sequence`, randomize transactions in `body`, and send them to the
target agent's sequencer.
