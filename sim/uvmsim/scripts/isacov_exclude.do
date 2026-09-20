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

# CSR value coverpoint is wired to the WRONG trace field. cp_csr_value reads
# ins.current.imm (RV32Zicsr_coverage.svh:70/150/242/...), but add_csr() -- the
# ONLY function that ever sets a CSR field -- writes the CSR address into imm2,
# never imm (RISCV_instruction_base.svh:485-486). For register-form csrrw/csrrs/
# csrrc, nothing else touches imm, so it stays at its default 0 -- only "zero" can
# ever fire; neg/pos are permanently dead regardless of stimulus or which CSR/value
# is targeted. (OBS-068 session, 2026-09-20)
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrw_cg/cp_csr_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrw_cg/cp_csr_value/pos} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrs_cg/cp_csr_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrs_cg/cp_csr_value/pos} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrc_cg/cp_csr_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrc_cg/cp_csr_value/pos} -reason EUR

# For the immediate-form csrrwi/csrrsi/csrrci, imm IS populated -- but with the
# 5-bit UNSIGNED zimm operand (via add_imm(), same field the ALSO-present
# cp_imm_value coverpoint reads), never the CSR value either. zimm cannot be
# negative by construction (0-31): neg is dead on BOTH coverpoints for these
# three; zero/pos are real and already reachable (unaffected).
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrwi_cg/cp_csr_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrwi_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrsi_cg/cp_csr_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrsi_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrci_cg/cp_csr_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32zicsr_csrrci_cg/cp_imm_value/neg} -reason EUR

# Branch/jal targets: gen_disass_map.sh prints the resolved absolute target as
# BARE hex with no "0x" prefix ("bge x5,x6,8000013c"), but get_imm()
# (RISCV_instruction_base.svh:248) only recognizes hex when 0x-prefixed --
# everything else falls to decimal .atoi(), which reads the leading
# decimal-looking digits of the hex text and stops at the first hex letter.
# Result: always a meaningless positive number, never neg, essentially never
# exactly zero. Even a corrected parse would not close these bins -- every kernel
# in this project links at a fixed base >= 0x80000000, so a correctly-parsed
# target is always a negative 32-bit value, permanently closing "neg" but
# permanently opening "pos"/"zero" instead. Full trace: OBS-068.
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_b*_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_b*_cg/cp_imm_value/zero} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_jal_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_jal_cg/cp_imm_value/zero} -reason EUR

# slli/srli/srai's shift-amount operand and lui/auipc's 20-bit upper-immediate
# ARE correctly 0x-hex-parsed ("slli x13,x11,0x1", "auipc x10,0x7") -- this is a
# genuine field-width limit, not a parser bug: both are architecturally unsigned
# magnitudes in this operand position (5-bit shamt; 20-bit upper-imm), so a
# negative int32 value can never occur here regardless of stimulus. lui's
# "zero"/auipc's "neg" siblings are NOT excluded -- they are real, reachable gaps
# (see isacov_fill).
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_slli_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_srli_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_srai_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_lui_cg/cp_imm_value/neg} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_auipc_cg/cp_imm_value/neg} -reason EUR

# jal's rd (return address) and jalr's rd (return address) / rs1 (jump-through
# base) are all real code addresses -- and every kernel in this project links at
# a fixed base >= 0x80000000 (same fact as the branch/jal exclusion above), so
# these three registers are ALWAYS a negative int32 value. Not a parsing defect
# this time -- rd_val/rs1_val come from real x_wdata content -- but a genuine,
# config-invariant consequence of the fixed link base: "pos" can never occur on
# a PC-valued register in this build. jal_cg's "zero" IS reachable (rd=x0, the
# `j label` pseudo-op renders as `jal x0,...`, and x0 always reads 0) and stays
# a live target -- only "pos" is excluded here.
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_jal_cg/cp_rd_sign/pos} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_jalr_cg/cp_rd_sign/pos} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_jalr_cg/cp_rs1_sign/pos} -reason EUR
coverage exclude -cvgpath {/RISCV_coverage_pkg/RISCV_coverage/RISCV_coverage__1/rv32i_jalr_cg/cp_rs1_sign/zero} -reason EUR

# rv32i_lhu_cg/cp_rd_sign/neg was PROPOSED here as EUR (lhu zero-extends, so a
# negative 32-bit rd_val should be architecturally impossible) but the
# hits-invariant gate (apply_isacov_exclude.sh) caught it as WRONG: 186 real
# hits appeared after the isacov_fill round-2 stimulus (0 before). NOT excluded
# -- see OBS-069 (docs/RTL_OBSERVATIONS.md) for the open, not-yet-root-caused
# writeup. Left as a live, counted bin.

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
