#!/usr/bin/env bash
# Build a PC-keyed disassembly map for riscvISACOV from a kernel ELF.
#
#   usage: gen_disass_map.sh <kernel.elf> [out.txt]
#
# Output, one line per instruction:
#     <pc_hex> <insn_hex> <mnemonic> <operands>
# isacov_pkg hands everything from field 2 onward to riscvISACOV verbatim,
# which is the "<hex> <mnem> <ops>" shape its $sscanf(disass,"%s %s %s")
# expects (RISCV_coverage_base.svh:1381).
#
# -M numeric,no-aliases is REQUIRED, not cosmetic:
#   * numeric     -> "x5" not "t0".  RISCV_instruction_base.svh:119 tests
#                    ops[i].key[0]=="x" and parses the register NUMBER out of
#                    the text; ABI names score nothing.
#   * no-aliases  -> "csrrs x5,0xfc1,x0" not "csrr t0,nw".  Pseudo-instructions
#                    are not RV32I mnemonics and match no covergroup.
# Vortex custom ops render as ".insn 4, 0x..." and correctly match nothing.
set -euo pipefail

ELF=${1:?usage: gen_disass_map.sh <kernel.elf> [out.txt]}
OUT=${2:-isacov_map.txt}

OBJDUMP=${OBJDUMP:-}
if [ -z "$OBJDUMP" ]; then
    for c in riscv32-unknown-elf-objdump riscv64-unknown-elf-objdump llvm-objdump; do
        command -v "$c" >/dev/null 2>&1 && { OBJDUMP=$c; break; }
    done
fi
[ -n "$OBJDUMP" ] || { echo "no riscv objdump found; set OBJDUMP=" >&2; exit 1; }

"$OBJDUMP" -d -M numeric,no-aliases "$ELF" \
  | awk '
      # objdump line: "80000000:\tfc1022f3          \tcsrrs\tx5,0xfc1,x0"
      /^[ \t]*[0-9a-f]+:/ {
          line = $0
          sub(/^[ \t]+/, "", line)
          n = index(line, ":")
          pc = substr(line, 1, n-1)
          rest = substr(line, n+1)
          gsub(/^[ \t]+/, "", rest)
          # first field of rest is the instruction word (hex, no spaces)
          nf = split(rest, f, /[ \t]+/)
          if (nf < 2) next
          if (f[1] !~ /^[0-9a-f]+$/) next
          # drop any trailing "# ..." objdump annotation
          if (match(rest, /[ \t]#[ \t]/)) { rest = substr(rest, 1, RSTART-1); nf = split(rest, f, /[ \t]+/) }
          out = pc " " f[1]
          for (i = 2; i <= nf; i++) out = out " " f[i]
          print out
      }' > "$OUT"

echo "[gen_disass_map] $(wc -l < "$OUT") instructions -> $OUT"
