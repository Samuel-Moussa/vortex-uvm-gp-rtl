#!/usr/bin/env bash
# run_seeds.sh — thin wrapper: for seed in START..END, generate a divergence
# kernel with simtgen.py, build+run it through the SAME make sim flow every
# other kernel uses, log pass/fail to a CSV.
#
# Usage: run_seeds.sh <start_seed> <end_seed> [csv_out]
#
# Safety (per CLAUDE.md): checks for a live vsim/vlog/vopt before EACH build
# (never recompile while a sim holds the Questa work library) and aborts the
# whole run rather than racing it.

set -euo pipefail

START=${1:?usage: run_seeds.sh start_seed end_seed [csv_out]}
END=${2:?usage: run_seeds.sh start_seed end_seed [csv_out]}
CSV=${3:-/tmp/simtgen_run_seeds.csv}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UVMSIM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"          # Vortex/sim/uvmsim
KERNEL_DIR="$(cd "$UVMSIM_DIR/../../tests/kernel" && pwd)"  # Vortex/tests/kernel

echo "seed,name,result,cycles,instructions,data_compared,errors" > "$CSV"

for seed in $(seq "$START" "$END"); do
  name="simtgen_div_s${seed}"
  out_dir="$KERNEL_DIR/$name"

  if pgrep -fa 'vsim|vlog|vopt' > /dev/null; then
    echo "ABORT: a Questa process is running — refusing to recompile (see CLAUDE.md)." >&2
    exit 1
  fi

  echo "== seed=$seed -> $name =="
  python3 "$SCRIPT_DIR/simtgen.py" --seed "$seed" --out "$out_dir" --name "$name"

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

  echo "$seed,$name,$result,$cycles,$instrs,$dcmp,$errs" >> "$CSV"
  echo "  -> $result (cycles=$cycles instrs=$instrs data_compared=$dcmp errors=$errs) log=$log"
done

echo "Done. CSV: $CSV"
