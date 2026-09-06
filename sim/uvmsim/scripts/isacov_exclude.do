# ═══════════════════════════════════════════════════════════════════════════
# riscvISACOV (L1) coverage exclusions
# ═══════════════════════════════════════════════════════════════════════════
# Applied by apply_isacov_exclude.sh in TWO STAGES, because the two classes have
# fundamentally different semantics and only the first is hits-invariant:
#
#   EUR  = structurally unreachable. These bins CANNOT be hit on this DUT or by
#          this toolflow, so removing them must change the DENOMINATOR ONLY.
#          If applying stage 1 changes the hit count, a waiver is wrong -- the
#          apply script gates on exactly that.
#
#   EOTH = executed / reachable, but NOT claimed as a verification target of this
#          project. Removing these DOES legitimately drop covered bins.
#
# NEVER merge the two classes into one number. Report:
#   "L1 ISA-behaviour coverage" = after EUR + EOTH
#   and state that register-index bins are excluded, with the reason.
# ═══════════════════════════════════════════════════════════════════════════

# ── CLASS EUR: STRUCTURALLY UNREACHABLE (RTL / toolflow cited) ──────────────
#
# fence.i -- VX_decode.sv:291 never inspects funct3, so `fence.i` decodes
# identically to a data `fence`; INST_FENCE_I (VX_gpu_pkg.sv:336) is a dead
# localparam with no execute-side consumer. The mnemonic can never reach the
# coverage sampler as a distinct instruction. (OBS-050)
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zifencei_fence_i_cg} -reason EUR

# nop -- gen_disass_map.sh:32 disassembles with `objdump -M numeric,no-aliases`,
# which is REQUIRED so that every other instruction yields a register-numbered,
# non-pseudo mnemonic (this is what makes every other covergroup's register and
# operand coverpoints work at all). `nop` is purely a disassembler-side alias for
# `addi x0,x0,0`, so the literal string "nop" can never appear in a map produced
# by this pipeline, and rv32i_nop_cg's hardcoded `ins_str=="nop"` check can never
# match -- regardless of stimulus or build defines. (OBS-056)
#
# NOTE: this is a TOOLFLOW structural limit, not an RTL one. The encoding itself
# executes correctly on the DUT and is counted under rv32i_addi_cg.
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_nop_cg} -reason EUR

# ── CLASS EOTH: REACHABLE, BUT NOT A CLAIMED VERIFICATION TARGET ────────────
#
# cp_*_reg_assign asks WHICH architectural register was used as rd / rs1 / rs2 /
# fd / fs1 / fs2 / fs3. These bins are NOT structurally unreachable -- they are
# reachable with different stimulus. They are excluded as a documented
# METHODOLOGY decision (docs/RISCVISACOV_STATUS.md 6c, VERIFICATION_PLAN_v2.md
# W-13):
#
#   1. Vortex's register file is a banked RAM with uniform indexing. x5 vs x6 is
#      structurally symmetric -- there is no per-index logic that could break,
#      and the index decode is already exercised by address-bus toggle coverage.
#   2. WHICH register the compiler allocates is a property of the COMPILER, not
#      of the DUT. Reaching x28 requires manufacturing register pressure, which
#      verifies nothing about the hardware.
#   3. It is 92% of this denominator (5,951 of 6,469 bins), so leaving it in
#      makes the aggregate a measure of the compiler's register allocator rather
#      than of the design under test.
#
# This is standard practice in CPU DV (OpenHW take the same position). It is
# recorded as a separate class precisely so the claim stays honest: it is a
# scope decision, NOT a structural-unreachability argument.
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/*/cp_*_reg_assign} -reason EOTH
