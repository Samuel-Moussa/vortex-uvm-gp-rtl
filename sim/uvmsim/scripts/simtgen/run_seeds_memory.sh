#!/usr/bin/env bash
# run_seeds_memory.sh — S2 memory-axis analogue of run_seeds.sh: for each
# seed in the given LIST (not a contiguous range — S2 seeds are hand-picked
# to cover all 3 coalesce patterns), generate+build+run a simtgen_mem_s<seed>
# kernel and log pass/fail to a CSV.
#
# Usage: run_seeds_memory.sh "<seed1> <seed2> ..." [csv_out]
set -euo pipefail

SEEDS=${1:?usage: run_seeds_memory.sh "seed1 seed2 ..." [csv_out]}
CSV=${2:-/tmp/simtgen_run_seeds_memory.csv}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UVMSIM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
KERNEL_DIR="$(cd "$UVMSIM_DIR/../../tests/kernel" && pwd)"

echo "seed,name,pattern,result,cycles,instructions,data_compared,errors" > "$CSV"

for seed in $SEEDS; do
  name="simtgen_mem_s${seed}"
  out_dir="$KERNEL_DIR/$name"

  if pgrep -fa 'vsim|vlog|vopt' > /dev/null; then
    echo "ABORT: a Questa process is running — refusing to recompile (see CLAUDE.md)." >&2
    exit 1
  fi

  echo "== seed=$seed -> $name =="
  python3 "$SCRIPT_DIR/simtgen.py" --seed "$seed" --axis memory --out "$out_dir" --name "$name"
  pattern=$(grep -m1 "Global pattern:" "$out_dir/main.cpp" | sed 's/.*pattern: //;s/\..*//')

  log="/tmp/simtgen_${name}.log"
  ( cd "$UVMSIM_DIR" && env -u VORTEX_UVM_HOME make sim \
      TEST=kernel_launch_test PROGRAM_NAME="$name" \
      CLUSTERS=1 CORES=1 WARPS=4 THREADS=4 TIMEOUT=50000 ) > "$log" 2>&1 \
    || true

  result="FAIL"
  grep -q "TEST PASSED" "$log" && result="PASS"
  cycles=$(grep -oE 'Total Cycles: [0-9]+' "$log" | tail -1 | grep -oE '[0-9]+' || echo "")
  instrs=$(grep -oE 'Instructions: [0-9]+' "$log" | tail -1 | grep -oE '[0-9]+' || echo "")
  dcmp=$(grep -oE 'data_compared=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+' || echo "")
  errs=$(grep -oE 'Errors: [0-9]+' "$log" | tail -1 | grep -oE '[0-9]+' || echo "")

  echo "$seed,$name,$pattern,$result,$cycles,$instrs,$dcmp,$errs" >> "$CSV"
  echo "  -> $result pattern=$pattern (cycles=$cycles instrs=$instrs data_compared=$dcmp errors=$errs) log=$log"
done

echo "Done. CSV: $CSV"
