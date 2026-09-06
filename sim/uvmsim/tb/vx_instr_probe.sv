// =============================================================================
// vx_instr_probe.sv  —  White-box architectural instruction coverage (ARCH-COV)
//
// Plan item: instr_class_cg (Stage-2 functional coverage, design-intent layer).
// Samples decoded instructions at the DISPATCH stage — the first point where an
// instruction has been classified to an execution unit. This is GPU-intent
// coverage (instruction mix, divergence), NOT bus-traffic coverage.
//
// HOW IT BINDS (passive, no DUT edits):
//   bind VX_dispatch vx_instr_probe #(...) u_instr_probe (.*);
//   VX_dispatch owns `dispatch_if [NUM_EX_UNITS]` as its .master output array
//   (instantiated in VX_issue_slice.sv:83). The probe reads those interfaces;
//   it NEVER drives them (the real consumer drives .ready).
//
// KEY ENCODING FACTS (confirmed from RTL, not assumed):
//   - ex_type (instruction CLASS) is the ARRAY INDEX, not a payload field:
//       EX_ALU=0, EX_LSU=1, EX_SFU=2, EX_FPU=3, EX_TCU=4   (VX_gpu_pkg.sv:113-119)
//     dispatch_if[i].valid means "an EX_unit-i instruction issued this cycle".
//   - op_type (4-bit SUB-opcode within the class) IS a payload field:
//       dispatch_t.op_type  (VX_gpu_pkg.sv:638)
//       ALU ops: INST_ALU_*  (:184+),  LSU ops: INST_LSU_* (:317+)
//       SFU ops: INST_SFU_*  (:374+) — TMC/WSPAWN/SPLIT/JOIN/BAR/PRED/CSR*
//   - tmask width = `SIMD_WIDTH (dispatch_t.tmask, :636) → divergence signal
//   - wis = warp-in-schedule index (dispatch_t.wis, :634)
//
// SAMPLING: one .sample() per (dispatch_if[i].valid && dispatch_if[i].ready),
//   i.e. per instruction actually accepted into a unit. No vacuous samples.
//
// -----------------------------------------------------------------------------
// COVERAGE STRUCTURE  (revised — per-class covergroup variants)
// -----------------------------------------------------------------------------
// Previous revision used ONE covergroup type carrying every class's op
// coverpoint, gated by `iff (ex_class==N)`. That meant each of the 5 bound
// instances dragged in ~4 op-coverpoints it could never hit, plus a 5-way
// `cp_class` that could only ever reach 1 bin. Those structurally-unreachable
// bins inflated the denominator and pinned the reported % artificially low
// (e.g. the ALU instance capped at 40% despite hitting 12/14 real ALU ops).
//
// This revision uses ONE covergroup TYPE PER CLASS. Each instance carries only
// the coverpoints that can actually fire for its unit. Nothing reachable is
// removed — only impossible-per-instance bins are gone. Genuine holes (e.g.
// czeq/czne Zicond ops, or an LSU/SFU class a given program never exercises)
// remain fully visible and simply read ZERO until a program exercises them.
//
//   - cp_class       : DROPPED. It was a per-instance constant; the class is now
//                      encoded in the instance name (instr_class_cg_alu, _lsu…),
//                      and "did this class issue" is visible from its coverpoints.
//   - cross_class_threads : DROPPED. Degenerated to cp_active_threads per
//                      instance (class is constant), which is still present.
//   - cross_sfu_threads   : KEPT (SFU only). Genuinely meaningful: do the
//                      divergence-control ops fire under partial masks?
//
// Coverage lands in the SAME merged UCDB as everything else — a covergroup in a
// bound RTL module merges identically to the collector's covergroups.
// =============================================================================

// Note: no `include of VX_define.vh — this module compiles in the UVM vlog pass
// which lacks the RTL incdir. All needed constants come from VX_gpu_pkg (imported
// below) and from the dispatch_if field widths. No RTL macros are referenced.

module vx_instr_probe import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0
) (
    input wire clk,
    input wire reset,
    VX_dispatch_if.slave dispatch_if [NUM_EX_UNITS]   // OBSERVE ONLY — never drive .ready
);

    // EX-unit class indices. These mirror the dispatch array index the original
    // probe already relied on (it binned cp_class as {0..4} and constructed with
    // new(gi)). Kept as explicit local params — proven mapping, no dependency on
    // package enum identifier spelling.
    localparam int C_ALU = 0;
    localparam int C_LSU = 1;
    localparam int C_SFU = 2;
    localparam int C_FPU = 3;
    localparam int C_TCU = 4;

    // SIMD width WITHOUT the `SIMD_WIDTH macro: this module compiles in the UVM
    // vlog pass, which does NOT include VX_config.vh, so the macro is undefined
    // here. Derive the width from the actual tmask field of dispatch_t instead —
    // always correct, never macro-dependent.
    localparam int SIMD_W = $bits(dispatch_if[0].data.tmask);
    // XLEN without the `XLEN macro (no RTL incdir in the UVM pass): XLENB is a
    // VX_gpu_pkg localparam (XLEN/8), imported above. Used for the RV32 LD/SD waiver.
    localparam int PROBE_XLEN = XLENB * 8;

    // =========================================================================
    // G-6: operand-value coverage. dispatch_t already carries rs1_data/rs2_data/
    // rs3_data as per-SIMD-lane arrays (VX_gpu_pkg.sv:627-629) at this probe's
    // existing bind point -- a covergroup edit, not a new probe or RTL change.
    // Before this, L2 had ZERO coverpoints reading an operand value anywhere
    // (independent audit, plan §4b).
    //
    // classify_sign reduces one SIMD-wide operand to a 4-way class, masked by
    // the ACTIVE lanes only (tmask) -- an inactive lane's data is a don't-care,
    // not a zero, and must not be allowed to pollute the classification:
    //   ZERO / POS / NEG   : every active lane agrees on that category
    //   MIXED              : active lanes disagree -- itself a real SIMT fact
    //                        (this operand genuinely diverges in VALUE, not
    //                        just in whether the lane is active at all)
    // The MSB-based neg test doubles correctly as the IEEE-754 sign bit for a
    // 32-bit float operand (sign is bit 31 either way, including -0.0), so this
    // is reused as-is for the FPU class below. It is NOT a full float-special
    // classifier (NaN/Inf/denorm) -- that is a separate, larger follow-up
    // (plan G-6's cp_fp_class), deliberately not attempted here.
    // =========================================================================
    typedef enum { SIGN_ZERO, SIGN_POS, SIGN_NEG, SIGN_MIXED } sign_class_e;

    function automatic sign_class_e classify_sign(
        input logic [SIMD_W-1:0][PROBE_XLEN-1:0] data,
        input logic [SIMD_W-1:0]                 tmask
    );
        bit seen_pos, seen_neg, seen_zero;
        seen_pos  = 1'b0;
        seen_neg  = 1'b0;
        seen_zero = 1'b0;
        for (int i = 0; i < SIMD_W; i++) begin
            if (tmask[i]) begin
                if (data[i] == '0)         seen_zero = 1'b1;
                else if (data[i][PROBE_XLEN-1]) seen_neg = 1'b1;
                else                       seen_pos  = 1'b1;
            end
        end
        if (seen_pos  && !seen_neg && !seen_zero) return SIGN_POS;
        if (seen_neg  && !seen_pos && !seen_zero) return SIGN_NEG;
        if (seen_zero && !seen_pos && !seen_neg)  return SIGN_ZERO;
        return SIGN_MIXED;
    endfunction

    // =========================================================================
    // G-3: divide-corner coverage (div-by-zero, INT_MIN/-1 overflow) -- the two
    // classic MULDIV bugs, on the same rs1_data/rs2_data already read for G-6.
    // Mask-qualified the same way as classify_sign: an inactive lane cannot
    // contribute a corner case. Zero-divisor applies to all four div/rem ops;
    // INT_MIN/-1 overflow is a SIGNED-only corner (div_edge already drives it
    // for DIV/REM; it does not apply to DIVU/REMU, so `signed_op` gates it off
    // there rather than mis-scoring an unsigned pair as "overflow").
    // =========================================================================
    typedef enum { DIV_NORMAL, DIV_BY_ZERO, DIV_OVERFLOW, DIV_MIXED } div_special_e;

    function automatic div_special_e classify_div_special(
        input logic [INST_ALU_BITS-1:0]          op_type,
        input logic [SIMD_W-1:0][PROBE_XLEN-1:0] rs1_data,
        input logic [SIMD_W-1:0][PROBE_XLEN-1:0] rs2_data,
        input logic [SIMD_W-1:0]                 tmask
    );
        bit seen_zero, seen_overflow, seen_normal, signed_op;
        signed_op   = (op_type == INST_M_DIV) || (op_type == INST_M_REM);
        seen_zero   = 1'b0;
        seen_overflow = 1'b0;
        seen_normal = 1'b0;
        for (int i = 0; i < SIMD_W; i++) begin
            if (tmask[i]) begin
                if (rs2_data[i] == '0) begin
                    seen_zero = 1'b1;
                end else if (signed_op && rs1_data[i] == {1'b1, {(PROBE_XLEN-1){1'b0}}}
                                        && rs2_data[i] == {PROBE_XLEN{1'b1}}) begin
                    seen_overflow = 1'b1;
                end else begin
                    seen_normal = 1'b1;
                end
            end
        end
        if (seen_zero     && !seen_overflow && !seen_normal) return DIV_BY_ZERO;
        if (seen_overflow && !seen_zero     && !seen_normal) return DIV_OVERFLOW;
        if (seen_normal   && !seen_zero     && !seen_overflow) return DIV_NORMAL;
        return DIV_MIXED;
    endfunction

    // =========================================================================
    // cp_imm_sign (G-6 follow-up): the decoded immediate (op_args.alu.imm) is a
    // single warp-uniform value, not a per-lane array, so this reuses
    // classify_sign's 3 real categories (MIXED is structurally impossible for
    // a scalar and will simply never appear). Gated on use_imm at the call
    // site -- the raw imm field is a decode artifact, not a real operand, on
    // any register-form instruction.
    // =========================================================================
    function automatic sign_class_e classify_scalar_sign(input logic [PROBE_XLEN-1:0] val);
        if (val == '0)              return SIGN_ZERO;
        if (val[PROBE_XLEN-1])       return SIGN_NEG;
        return SIGN_POS;
    endfunction

    // =========================================================================
    // cp_fp_class (G-6 follow-up): real IEEE-754 binary32 decode -- NOT a reuse
    // of classify_sign's MSB trick. Assumes binary32 layout (sign[31]/
    // exp[30:23]/mantissa[22:0]), valid because F2F is RV64/D-only and waived
    // on this RV32 build (same config-aware assumption already used for the
    // F2F ignore_bins above) -- rs data here is always a real float32 value.
    // Mask-qualified the same way as classify_sign: exactly one class agreed
    // by all active lanes, else MIXED.
    // =========================================================================
    typedef enum { FPCLASS_ZERO, FPCLASS_NORMAL, FPCLASS_DENORM,
                   FPCLASS_INF,  FPCLASS_NAN,    FPCLASS_MIXED } fp_class_e;

    function automatic fp_class_e classify_fp_class(
        input logic [SIMD_W-1:0][PROBE_XLEN-1:0] data,
        input logic [SIMD_W-1:0]                 tmask
    );
        bit seen_zero, seen_normal, seen_denorm, seen_inf, seen_nan;
        automatic int unsigned n;
        seen_zero = 1'b0; seen_normal = 1'b0; seen_denorm = 1'b0;
        seen_inf  = 1'b0; seen_nan    = 1'b0;
        for (int i = 0; i < SIMD_W; i++) begin
            if (tmask[i]) begin
                logic [7:0]  exp_f  = data[i][30:23];
                logic [22:0] mant_f = data[i][22:0];
                if (exp_f == 8'hFF) begin
                    if (mant_f == '0) seen_inf = 1'b1;
                    else              seen_nan = 1'b1;
                end else if (exp_f == '0) begin
                    if (mant_f == '0) seen_zero   = 1'b1;
                    else              seen_denorm = 1'b1;
                end else begin
                    seen_normal = 1'b1;
                end
            end
        end
        n = 0;
        if (seen_zero)   n++;
        if (seen_normal) n++;
        if (seen_denorm) n++;
        if (seen_inf)    n++;
        if (seen_nan)    n++;
        if (n > 1)       return FPCLASS_MIXED;
        if (seen_zero)   return FPCLASS_ZERO;
        if (seen_normal) return FPCLASS_NORMAL;
        if (seen_denorm) return FPCLASS_DENORM;
        if (seen_inf)    return FPCLASS_INF;
        return FPCLASS_NAN;
    endfunction

    // =========================================================================
    // Per-class covergroup TYPES. Each carries only the coverpoints reachable
    // for its EX unit. The shared cp_active_threads / cp_warp definitions are
    // repeated rather than factored out, so each type is self-contained and the
    // sample signature is explicit per class.
    //
    // NOTE on divergence bins: cp_active_threads edges are written for the actual
    // SIMD width (derived as SIMD_W). `partial` spans [2 : SIMD_W-1]; if SIMD_W
    // is small (<=2) that range may be empty, which is correct.
    // =========================================================================

    // ---- ALU ----------------------------------------------------------------
    covergroup alu_class_cg with function sample(
        logic [INST_ALU_BITS-1:0] op_type,
        logic [ALU_TYPE_BITS-1:0] xtype,
        int                       active_thr,
        logic [ISSUE_WIS_W-1:0]   wis,
        sign_class_e              rs1_sign,
        sign_class_e              rs2_sign,
        div_special_e             div_special,
        logic                     use_imm,
        sign_class_e              imm_sign
    );
        option.per_instance = 1;
        option.name         = "instr_class_cg_alu";

        // EX_ALU multiplexes FOUR disjoint op encodings onto the same op_type
        // field, discriminated ONLY by op_args.alu.xtype (VX_decode.sv:509 for
        // VOTE/SHFL). The numeric spaces collide exactly:
        //   INST_ALU_ADD == INST_BR_BEQ == INST_M_MUL == VOTE_ALL == 4'b0000
        // so an unqualified coverpoint counts beq/mul/vote.all as `add`.
        // Every ALU op coverpoint below is therefore gated on xtype. (OBS-049)
        cp_xtype : coverpoint xtype {
            bins arith  = { ALU_TYPE_ARITH };
            bins branch = { ALU_TYPE_BRANCH };
            bins muldiv = { ALU_TYPE_MULDIV };
            bins other  = { ALU_TYPE_OTHER };
        }

        cp_alu_op : coverpoint op_type iff (xtype == ALU_TYPE_ARITH) {
            bins add   = { INST_ALU_ADD };
            bins sub   = { INST_ALU_SUB };
            bins and_  = { INST_ALU_AND };
            bins or_   = { INST_ALU_OR  };
            bins xor_  = { INST_ALU_XOR };
            bins sll   = { INST_ALU_SLL };
            bins srl   = { INST_ALU_SRL };
            bins sra   = { INST_ALU_SRA };
            bins slt   = { INST_ALU_SLT };
            bins sltu  = { INST_ALU_SLTU };
            bins lui   = { INST_ALU_LUI };
            bins auipc = { INST_ALU_AUIPC };
            bins czeq  = { INST_ALU_CZEQ };   // Zicond — ZERO until a Zicond build runs
            bins czne  = { INST_ALU_CZNE };   // Zicond — ZERO until a Zicond build runs
        }

        // ---- BRANCH class (xtype == ALU_TYPE_BRANCH) -------------------------
        // Vortex folds branches, jumps and the system-return ops into EX_ALU.
        // Before OBS-049 these had NO bins at all -- branch direction and jump
        // form were entirely uncovered.
        cp_branch_op : coverpoint op_type iff (xtype == ALU_TYPE_BRANCH) {
            bins beq    = { INST_BR_BEQ };
            bins bne    = { INST_BR_BNE };
            bins blt    = { INST_BR_BLT };
            bins bge    = { INST_BR_BGE };
            bins bltu   = { INST_BR_BLTU };
            bins bgeu   = { INST_BR_BGEU };
            bins jal    = { INST_BR_JAL };
            bins jalr   = { INST_BR_JALR };
            bins ebreak = { INST_BR_EBREAK };
            // ecall/uret/sret/mret: Vortex has no trap architecture (waiver
            // W-11), and prepare.sh rewrites ecall->ebreak. Structurally
            // unreachable from any program this bench can run.
            ignore_bins no_trap_arch = { INST_BR_ECALL, INST_BR_URET,
                                         INST_BR_SRET,  INST_BR_MRET };
            bins other  = { INST_BR_OTHER };
        }

        // ---- MULDIV class (xtype == ALU_TYPE_MULDIV) -------------------------
        // The RV32M surface, as the DUT actually dispatches it. This is our
        // microarchitectural view; riscvISACOV's RV32M bank is the independent
        // architectural view of the same instructions.
        cp_muldiv_op : coverpoint op_type iff (xtype == ALU_TYPE_MULDIV) {
            bins mul    = { INST_M_MUL };
            bins mulh   = { INST_M_MULH };
            bins mulhsu = { INST_M_MULHSU };
            bins mulhu  = { INST_M_MULHU };
            bins div    = { INST_M_DIV };
            bins divu   = { INST_M_DIVU };
            bins rem    = { INST_M_REM };
            bins remu   = { INST_M_REMU };
        }

        // ---- OTHER class (xtype == ALU_TYPE_OTHER) = VOTE / SHFL -------------
        // Vortex-CUSTOM warp-collective ops. riscvISACOV has NO dvplan for
        // these (they are not RISC-V), so this coverpoint is the ONLY place
        // they can ever be scored. VX_decode.sv:516 sets op_type = funct3;
        // funct3[2] selects SHFL over VOTE, funct3[1:0] the sub-op.
        cp_vote_shfl_op : coverpoint op_type iff (xtype == ALU_TYPE_OTHER) {
            bins vote_all  = { {1'b0, INST_VOTE_ALL}  };
            bins vote_any  = { {1'b0, INST_VOTE_ANY}  };
            bins vote_uni  = { {1'b0, INST_VOTE_UNI}  };
            bins vote_bal  = { {1'b0, INST_VOTE_BAL}  };
            bins shfl_up   = { {1'b1, INST_SHFL_UP}   };
            bins shfl_down = { {1'b1, INST_SHFL_DOWN} };
            bins shfl_bfly = { {1'b1, INST_SHFL_BFLY} };
            bins shfl_idx  = { {1'b1, INST_SHFL_IDX}  };
        }

        cp_active_threads : coverpoint active_thr {
            bins one_divergent = { 1 };
            bins partial[]     = { [2 : SIMD_W-1] };
            bins uniform       = { SIMD_W };
        }

        cp_warp : coverpoint wis;

        // G-6: operand-value coverage, mask-qualified (see classify_sign above).
        // Ungated -- meaningful across arith/branch/muldiv/vote-shfl alike (a
        // branch's outcome, a compare's result and a vote's condition all read
        // rs1/rs2 the same way).
        cp_rs1_sign : coverpoint rs1_sign;
        cp_rs2_sign : coverpoint rs2_sign;

        // G-3: div-by-zero / INT_MIN-over-(-1), div_edge already drives both.
        cp_div_special : coverpoint div_special
            iff (xtype == ALU_TYPE_MULDIV &&
                 (op_type == INST_M_DIV  || op_type == INST_M_DIVU ||
                  op_type == INST_M_REM  || op_type == INST_M_REMU)) {
            bins normal   = { DIV_NORMAL };
            bins by_zero  = { DIV_BY_ZERO };
            bins overflow = { DIV_OVERFLOW };
            bins mixed    = { DIV_MIXED };
        }

        // G-6 follow-up: immediate sign, only meaningful when actually used.
        cp_imm_sign : coverpoint imm_sign iff (use_imm) {
            bins zero = { SIGN_ZERO };
            bins pos  = { SIGN_POS };
            bins neg  = { SIGN_NEG };
        }
    endgroup

    // ---- LSU ----------------------------------------------------------------
    covergroup lsu_class_cg with function sample(
        logic [INST_ALU_BITS-1:0] op_type,   // op_type is one shared-width field across classes
        int                       active_thr,
        logic [ISSUE_WIS_W-1:0]   wis,
        sign_class_e              rs2_sign   // store-data value; base address (rs1) not covered here
    );
        option.per_instance = 1;
        option.name         = "instr_class_cg_lsu";

        cp_lsu_op : coverpoint op_type {
            bins lb = { INST_LSU_LB };
            bins lh = { INST_LSU_LH };
            bins lw = { INST_LSU_LW };
            bins sb = { INST_LSU_SB };
            bins sh = { INST_LSU_SH };
            bins sw = { INST_LSU_SW };
            // LD/SD are 64-bit load/store — not encodable in RV32 (XLEN==32).
            // Config-aware waiver: these bins are active only on RV64 builds.
            ignore_bins rv32_no_ld = { INST_LSU_LD } with (PROBE_XLEN == 32);
            ignore_bins rv32_no_sd = { INST_LSU_SD } with (PROBE_XLEN == 32);
        }

        cp_active_threads : coverpoint active_thr {
            bins one_divergent = { 1 };
            bins partial[]     = { [2 : SIMD_W-1] };
            bins uniform       = { SIMD_W };
        }

        cp_warp : coverpoint wis;

        cp_rs2_sign : coverpoint rs2_sign;   // store-data sign; rs1 (address) not covered here on purpose
    endgroup

    // ---- SFU (richest: SIMT control + barriers + CSR) -----------------------
    covergroup sfu_class_cg with function sample(
        logic [INST_ALU_BITS-1:0] op_type,
        int                       active_thr,
        logic [ISSUE_WIS_W-1:0]   wis
    );
        option.per_instance = 1;
        option.name         = "instr_class_cg_sfu";

        cp_sfu_op : coverpoint op_type {
            bins tmc    = { INST_SFU_TMC };      // thread-mask control
            bins wspawn = { INST_SFU_WSPAWN };   // spawn warps
            bins split  = { INST_SFU_SPLIT };    // divergence split
            bins join_  = { INST_SFU_JOIN };     // reconverge
            bins bar    = { INST_SFU_BAR };      // barrier
            bins pred   = { INST_SFU_PRED };     // predicate
            bins csrrw  = { INST_SFU_CSRRW };
            bins csrrs  = { INST_SFU_CSRRS };
            bins csrrc  = { INST_SFU_CSRRC };
        }

        cp_active_threads : coverpoint active_thr {
            bins one_divergent = { 1 };
            bins partial[]     = { [2 : SIMD_W-1] };
            bins uniform       = { SIMD_W };
        }

        cp_warp : coverpoint wis;

        // The one genuinely meaningful cross: do divergence-control ops
        // (split/join/etc.) themselves fire under partial masks? = real SIMT.
        cross_sfu_threads : cross cp_sfu_op, cp_active_threads {
            // WSPAWN is a runtime-only primitive: it is issued exclusively from the
            // single-threaded spawn bootstrap (Vortex/kernel/src/vx_spawn.c:259,
            // vx_wspawn(active_warps, stub) executed on thread 0 before the SIMT region
            // spreads). No user SIMT kernel issues wspawn, and 35 diverse runs (all
            // kernels + directed tests + 12 constrained-random riscv-dv profiles) never
            // produced a multi-thread wspawn. Multi-thread wspawn is therefore
            // unreachable in any well-formed program; issuing vx_wspawn under a full
            // mask would redundantly re-spawn from every lane (broken/unsafe), not a
            // legitimate stimulus. Ignore <wspawn, partial|uniform>; keep the reachable
            // <wspawn, one_divergent>. Evidence-based structural (programming-model)
            // waiver — trip-wire: revisit if a kernel ever legitimately fans wspawn out
            // across active threads.
            ignore_bins wspawn_multithread =
                binsof(cp_sfu_op.wspawn) &&
                ( binsof(cp_active_threads.partial) ||
                  binsof(cp_active_threads.uniform) );
        }
    endgroup

    // ---- FPU (sub-op decode — Phase 2) --------------------------------------
    // op_type is the INST_FPU_* sub-opcode (VX_gpu_pkg.sv:349-361). Every RV F/D
    // op maps to one of these 13 codes; F2I/F2U/I2F/U2F/CMP/F2F/MISC further split
    // on fmt/frm inside the FPU, but op_type is the coverage-relevant class here.
    covergroup fpu_class_cg with function sample(
        logic [INST_ALU_BITS-1:0] op_type,   // shared-width op_type field
        int                       active_thr,
        logic [ISSUE_WIS_W-1:0]   wis,
        sign_class_e              rs1_sign,
        sign_class_e              rs2_sign,
        sign_class_e              rs3_sign,  // FMA accumulator operand (fmadd/fnmadd/fnmsub)
        fp_class_e                rs1_class
    );
        option.per_instance = 1;
        option.name         = "instr_class_cg_fpu";

        cp_fpu_op : coverpoint op_type {
            bins fadd  = { INST_FPU_ADD };    // fadd / fsub (SUB=fmt[1])
            bins fmul  = { INST_FPU_MUL };
            bins fmadd = { INST_FPU_MADD };   // fmadd / fmsub
            bins fnmadd= { INST_FPU_NMADD };  // fnmadd / fnmsub
            bins fdiv  = { INST_FPU_DIV };
            bins fsqrt = { INST_FPU_SQRT };
            bins f2i   = { INST_FPU_F2I };    // fcvt.w.s / fcvt.l.s
            bins f2u   = { INST_FPU_F2U };    // fcvt.wu.s / fcvt.lu.s
            bins i2f   = { INST_FPU_I2F };    // fcvt.s.w / fcvt.s.l
            bins u2f   = { INST_FPU_U2F };    // fcvt.s.wu / fcvt.s.lu
            bins fcmp  = { INST_FPU_CMP };    // feq / flt / fle
            bins fmisc = { INST_FPU_MISC };   // sgnj/class/fmv/fmin/fmax
            // F2F = float<->double conversion (fcvt.s.d / fcvt.d.s). Requires the
            // D extension. The primary RV32 build compiles kernels rv32imaf (F only,
            // no D → soft-double libcalls, never an fcvt.d hardware op); RV64 builds
            // rv64imafd. Config-aware waiver: F2F is reachable only on a D-enabled
            // (RV64) build, mirroring the LSU LD/SD RV64-only waiver above.
            ignore_bins rv32_no_f2f = { INST_FPU_F2F } with (PROBE_XLEN == 32);
            bins f2f   = { INST_FPU_F2F };    // fcvt.s.d / fcvt.d.s (RV64/D only)
        }

        cp_active_threads : coverpoint active_thr {
            bins one_divergent = { 1 };
            bins partial[]     = { [2 : SIMD_W-1] };
            bins uniform       = { SIMD_W };
        }

        cp_warp : coverpoint wis;

        // G-6, float operands. classify_sign's MSB test is the IEEE-754 sign bit
        // for a 32-bit float operand (bit 31 either way, -0.0 included) -- this is
        // sign coverage only, NOT the fuller NaN/Inf/denorm classification the
        // plan's cp_fp_class calls for; that is a deliberately separate follow-up.
        // rs3 only samples meaningfully for fmadd/fnmadd (op_type-gated so the
        // other ops don't contribute a meaningless rs3 bin).
        cp_rs1_sign : coverpoint rs1_sign;
        cp_rs2_sign : coverpoint rs2_sign;
        cp_rs3_sign : coverpoint rs3_sign iff (op_type == INST_FPU_MADD || op_type == INST_FPU_NMADD);

        // G-6 follow-up: real IEEE-754 special-value coverage on rs1 (every
        // FPU op reads it). rs2/rs3 class coverage is a deliberate, separate
        // follow-up, not attempted here.
        cp_rs1_class : coverpoint rs1_class {
            bins zero   = { FPCLASS_ZERO };
            bins normal = { FPCLASS_NORMAL };
            bins denorm = { FPCLASS_DENORM };
            bins inf    = { FPCLASS_INF };
            bins nan    = { FPCLASS_NAN };
            bins mixed  = { FPCLASS_MIXED };
        }
    endgroup

    // ---- TCU (no op-decode: only INST_TCU_WMMA exists) ----------------------
    // Divergence + warp distribution only. INST_TCU_WMMA is the single TCU op, so
    // there is no sub-opcode coverpoint (nothing to decode).
    //
    // COLLECTIVE-OP WAIVER (cp_active_threads): WMMA is a warp-COLLECTIVE tensor op
    // — every lane of the warp contributes a slice of the A/B/D matrix tiles,
    // indexed by vx_thread_id() (vx_tensor.h:181). It is only well-formed under a
    // FULL (uniform) thread mask; a partial or single-thread mask would drop lanes
    // from the collective matrix product, which is not a valid WMMA (structurally
    // analogous to the wspawn multi-thread waiver in sfu_class_cg). tcu_test +
    // tcu_mt only ever produce uniform-mask WMMA. Waive one_divergent + partial;
    // cp_warp (which warp issued) is fully reachable and filled by tcu_mt.
    covergroup tcu_class_cg with function sample(
        int                     active_thr,
        logic [ISSUE_WIS_W-1:0] wis
    );
        option.per_instance = 1;
        option.name         = "instr_class_cg_tcu";

        cp_active_threads : coverpoint active_thr {
            ignore_bins collective_one_divergent = { 1 };            // WMMA needs full warp
            ignore_bins collective_partial       = { [2 : SIMD_W-1] };
            bins uniform                          = { SIMD_W };
        }

        cp_warp : coverpoint wis;
    endgroup

    // =========================================================================
    // Instantiate the correct covergroup per EX-unit dispatch interface and
    // sample on that interface's accepted handshake. The genvar index IS the
    // ex_type, so a generate-if selects the matching class covergroup.
    // =========================================================================
    genvar gi;
    generate
        for (gi = 0; gi < NUM_EX_UNITS; gi++) begin : g_cov

            if (gi == C_ALU) begin : g_alu
                alu_class_cg cg = new();
                always @(posedge clk) begin
                    if (!reset && dispatch_if[gi].valid && dispatch_if[gi].ready) begin
                        cg.sample(
                            dispatch_if[gi].data.op_type,
                            dispatch_if[gi].data.op_args.alu.xtype,
                            $countones(dispatch_if[gi].data.tmask),
                            dispatch_if[gi].data.wis,
                            classify_sign(dispatch_if[gi].data.rs1_data, dispatch_if[gi].data.tmask),
                            classify_sign(dispatch_if[gi].data.rs2_data, dispatch_if[gi].data.tmask),
                            classify_div_special(dispatch_if[gi].data.op_type,
                                                  dispatch_if[gi].data.rs1_data,
                                                  dispatch_if[gi].data.rs2_data,
                                                  dispatch_if[gi].data.tmask),
                            dispatch_if[gi].data.op_args.alu.use_imm,
                            classify_scalar_sign(dispatch_if[gi].data.op_args.alu.imm)
                        );
                    end
                end
            end

            else if (gi == C_LSU) begin : g_lsu
                lsu_class_cg cg = new();
                always @(posedge clk) begin
                    if (!reset && dispatch_if[gi].valid && dispatch_if[gi].ready) begin
                        cg.sample(
                            dispatch_if[gi].data.op_type,
                            $countones(dispatch_if[gi].data.tmask),
                            dispatch_if[gi].data.wis,
                            classify_sign(dispatch_if[gi].data.rs2_data, dispatch_if[gi].data.tmask)
                        );
                    end
                end
            end

            else if (gi == C_SFU) begin : g_sfu
                sfu_class_cg cg = new();
                always @(posedge clk) begin
                    if (!reset && dispatch_if[gi].valid && dispatch_if[gi].ready) begin
                        cg.sample(
                            dispatch_if[gi].data.op_type,
                            $countones(dispatch_if[gi].data.tmask),
                            dispatch_if[gi].data.wis
                        );
                    end
                end
            end

            else if (gi == C_FPU) begin : g_fpu
                fpu_class_cg cg = new();
                always @(posedge clk) begin
                    if (!reset && dispatch_if[gi].valid && dispatch_if[gi].ready) begin
                        cg.sample(
                            dispatch_if[gi].data.op_type,
                            $countones(dispatch_if[gi].data.tmask),
                            dispatch_if[gi].data.wis,
                            classify_sign(dispatch_if[gi].data.rs1_data, dispatch_if[gi].data.tmask),
                            classify_sign(dispatch_if[gi].data.rs2_data, dispatch_if[gi].data.tmask),
                            classify_sign(dispatch_if[gi].data.rs3_data, dispatch_if[gi].data.tmask),
                            classify_fp_class(dispatch_if[gi].data.rs1_data, dispatch_if[gi].data.tmask)
                        );
                    end
                end
            end

            else if (gi == C_TCU) begin : g_tcu
                // NOTE [Samuel 2026-06-29, REVIEW: Ahmad — coverage lane]: TCU is
                // a config-optional EX unit (EXT_TCU_ENABLE, OFF by default). The
                // TCU slot still exists in NUM_EX_UNITS but never dispatches when
                // disabled, so its covergroup was an UNREACHABLE 0% block (~195
                // bins) inflating the functional denominator. Only build it when
                // TCU is actually enabled.
`ifdef EXT_TCU_ENABLE
                tcu_class_cg cg = new();
                always @(posedge clk) begin
                    if (!reset && dispatch_if[gi].valid && dispatch_if[gi].ready) begin
                        cg.sample(
                            $countones(dispatch_if[gi].data.tmask),
                            dispatch_if[gi].data.wis
                        );
                    end
                end
`endif
            end

        end
    endgenerate

endmodule