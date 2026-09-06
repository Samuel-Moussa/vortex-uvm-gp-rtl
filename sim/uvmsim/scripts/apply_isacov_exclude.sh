#!/usr/bin/env bash
# Apply the riscvISACOV (L1) exclusions to a UCDB, in two gated stages.
#
#   usage: apply_isacov_exclude.sh <in.ucdb> [outdir]
#
# Produces, next to the input (or in <outdir>):
#   <base>_excl_struct.ucdb  -- EUR only  (structurally unreachable)
#   <base>_excl_isa.ucdb     -- EUR+EOTH  (the ISA-behaviour metric)
#
# The input UCDB is never modified.
#
# STAGE 1 IS GATED: an EUR exclusion is a claim that the bins CANNOT be hit, so
# removing them must change the denominator ONLY. If the hit count moves, the
# waiver is wrong and this script fails -- same discipline as the hits-invariant
# gate in merge_coverage.sh.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXCLUDE_DO="${SCRIPTS_DIR}/isacov_exclude.do"
[[ -f "$EXCLUDE_DO" ]] || { echo "missing $EXCLUDE_DO" >&2; exit 1; }

IN=${1:?usage: apply_isacov_exclude.sh <in.ucdb> [outdir]}
[[ -f "$IN" ]] || { echo "no such UCDB: $IN" >&2; exit 1; }
OUTDIR=${2:-$(dirname "$IN")}
BASE=$(basename "$IN" .ucdb)
mkdir -p "$OUTDIR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
grep    -- '-reason EUR'  "$EXCLUDE_DO" > "$WORK/eur.do"  || true
grep    -- '-reason EOTH' "$EXCLUDE_DO" > "$WORK/eoth.do" || true

STRUCT="${OUTDIR}/${BASE}_excl_struct.ucdb"
ISA="${OUTDIR}/${BASE}_excl_isa.ucdb"

# ---- helper: pull "<bins> <hits>" for the riscvISACOV package out of a UCDB ----
isacov_bins() {
    vcover report -cvg "$1" 2>/dev/null \
      | awk '/=== Instance: \/RISCV_coverage_pkg/{f=1} f && /Covergroup Bins/{print $3, $4; exit}'
}

read -r BINS0 HITS0 <<<"$(isacov_bins "$IN")"

echo "== stage 1: EUR (structurally unreachable) =="
vsim -viewcov "$IN" -c -do "do $WORK/eur.do; coverage save $STRUCT; quit -f;" \
    2>&1 | tee "$WORK/s1.log" | grep -Ei "had no effect|error" || true
if grep -q "had no effect" "$WORK/s1.log"; then
    echo "WARN: an EUR exclusion matched nothing (stale path?)" >&2
fi
read -r BINS1 HITS1 <<<"$(isacov_bins "$STRUCT")"

if [[ "$HITS0" != "$HITS1" ]]; then
    echo "FAIL: EUR exclusions changed the HIT count ($HITS0 -> $HITS1)." >&2
    echo "      A structural waiver must be hits-invariant. Fix the waiver." >&2
    exit 1
fi
echo "  hits-invariant OK: $HITS0 hits, bins $BINS0 -> $BINS1"

echo "== stage 2: EOTH (reachable, not a claimed target) =="
vsim -viewcov "$STRUCT" -c -do "do $WORK/eoth.do; coverage save $ISA; quit -f;" \
    2>&1 | tee "$WORK/s2.log" | grep -Ei "had no effect|error" || true
read -r BINS2 HITS2 <<<"$(isacov_bins "$ISA")"

pct() { awk -v h="$1" -v b="$2" 'BEGIN{ if(b>0) printf "%.2f", 100*h/b; else print "n/a" }'; }
echo
echo "  raw (no exclusions)      : $HITS0/$BINS0 = $(pct "$HITS0" "$BINS0")%"
echo "  + EUR  (structural)      : $HITS1/$BINS1 = $(pct "$HITS1" "$BINS1")%   <- denominator only"
echo "  + EOTH (ISA-behaviour)   : $HITS2/$BINS2 = $(pct "$HITS2" "$BINS2")%   <- register-index bins excluded"
echo
echo "  wrote: $STRUCT"
echo "         $ISA"
echo
echo "  When quoting the last figure, ALWAYS state that register-index"
echo "  (*_reg_assign) bins are excluded and why -- see isacov_exclude.do."
