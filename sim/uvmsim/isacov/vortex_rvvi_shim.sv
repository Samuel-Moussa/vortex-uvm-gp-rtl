// Copyright (c) 2026 -- Vortex UVM GP.  Apache-2.0.
// riscvISACOV itself is Apache-2.0 (Imperas) and is used UNMODIFIED from
// third_party/riscvISACOV; nothing in this file is derived from it.
//==============================================================================
// vortex_rvvi_shim.sv -- Vortex retirement  ->  RVVI-TRACE  ->  riscvISACOV
//------------------------------------------------------------------------------
// Bound into EVERY VX_commit instance (one shim, one rvviTrace, one coverage
// model per CORE), so per-core attribution comes from the UCDB hierarchy path
// exactly as it does for the existing probes.
//
// TWO SAMPLING MODES, selected at RUNTIME by +ISACOV_MODE=<A|B>:
//
//   A (default) -- LANE AS HART.  NHART = `NUM_THREADS and every ACTIVE SIMT
//       lane is sampled as its own hart.  This is the mode that reflects what
//       the GPU actually executed: the four lanes of a warp run the same PC
//       over DIFFERENT data, so lanes 1..3 contribute real operand and
//       register-value diversity that lane 0 alone never sees.
//
//   B -- LANE 0 ONLY.  The conservative baseline: one hart, thread 0.  Kept
//       because it is the mode in which any miscompare is trivially
//       attributable, and because it is the honest "no SIMT credit" number to
//       report alongside A.
//
// tmask GATING IS MANDATORY, NOT AN OPTIMISATION.  An inactive lane's `data`
// slot holds whatever the datapath last left there -- it is NOT an
// architectural result.  Sampling it would push junk into every REG_VALUE /
// REG_VALUE_SIGN coverpoint and inflate coverage silently, which is precisely
// the OBS-029 failure class (a green run that verified nothing).  Only
// tmask[l] == 1 lanes are ever sampled.
//
// HART NUMBERING.  commit_t carries ONE SIMD group per beat: `tmask` and
// `data` are `SIMD_WIDTH wide and `sid` is the group index
// (VX_gpu_pkg.sv:651-663), so a warp of `NUM_THREADS retires over
// `NUM_THREADS/`SIMD_WIDTH beats.  The hart id is therefore
//     hart = sid * `SIMD_WIDTH + lane
// and EVERY beat is sampled -- not just sop.  Gating on sop would silently
// drop every SIMD group above the first whenever SIMD_WIDTH < NUM_THREADS.
//
// riscvISACOV keeps its trace queue PER HART (traceDataQ[hart]), so mapping
// lanes onto harts is also what keeps a future EXTENDED-level REG_HAZARD
// analysis honest -- folding four lanes into hart 0 would fabricate hazards
// between threads that never had a dependency.
//
// WHAT DRIVES THE MODEL
//   riscvISACOV keys on DISASSEMBLY TEXT, not on the instruction word
//   (RISCV_coverage_base.svh:1381).  The text comes from isacov_pkg's static
//   PC->text map built by gen_disass_map.sh from the kernel's own objdump.
//   A PC with no map entry yields "" which matches no covergroup -- the
//   correct behaviour for Vortex custom ops, which objdump renders as `.4byte`
//   and which are covered by OUR collector instead (vx_instr_probe).
//
// rvviTrace fields are all `wire` (rvviTrace.sv:67-104), so they must be
// DRIVEN by continuous assignment from registered state -- a class cannot
// write them.
//
// GATED on +ISACOV.  Without it nothing is sampled and the run is unchanged.
//==============================================================================
`include "VX_define.vh"
`include "RISCV_coverage.svh"    // brings `coverage` into THIS compilation unit

module vortex_rvvi_shim import VX_gpu_pkg::*; (
    input wire clk,
    input wire reset,
    VX_commit_if commit_arb_if [`ISSUE_WIDTH]     // read-only: no modport
);
    localparam int ILEN=32, XLEN=32, FLEN=32, VLEN=256;
    localparam int LANES = `SIMD_WIDTH;           // lanes per commit beat
    localparam int NHART = `NUM_THREADS;          // one hart per SIMT lane
    localparam int RETIRE = 1;

    rvviTrace #(ILEN, XLEN, FLEN, VLEN, NHART, RETIRE) rvvi();

    logic                  r_valid   [NHART];
    logic [63:0]           r_order   [NHART];
    logic [ILEN-1:0]       r_insn    [NHART];
    logic [XLEN-1:0]       r_pc      [NHART];
    logic [31:0]           r_x_wb    [NHART];
    logic [31:0]           r_f_wb    [NHART];
    logic [31:0][FLEN-1:0] r_f_wdata [NHART];

    // x_wdata is a FULL 32-REGISTER SNAPSHOT, not "the value written this
    // cycle". RVVI defines x_wdata[r] as register r's current value and x_wb[r]
    // as the flag that r changed on THIS retirement, and riscvISACOV depends on
    // that: RISCV_instruction_base.svh:444 reads
    //     current.rs1_val = prev.x_wdata[rs1]
    // i.e. source-operand values come from the PREVIOUS retirement's snapshot.
    //
    // Driving only the rd slot (the obvious-looking shortcut) makes every
    // source operand read as 0, so cp_rs1_sign / cp_rs2_sign can only ever hit
    // their `zero` bin and every REG_VALUE coverpoint is fed a constant. That
    // is not a stimulus gap, it is fabricated data -- and it is invisible,
    // because the run still passes and coverage still moves. Measured: with the
    // shortcut, lane-as-hart (4,581 samples) scored EXACTLY the same as lane 0
    // alone (1,677), because the only lane-varying quantity left was rd's sign.
    //
    // So each hart carries its own architectural register file, updated on
    // every writeback. Per-hart is correct for SIMT: each thread has its own
    // registers.
    logic [31:0][XLEN-1:0] r_x_wdata [NHART];

    assign rvvi.clk = clk;
    for (genvar h = 0; h < NHART; ++h) begin : g_hart
        initial begin
            r_valid[h] = 1'b0; r_order[h] = '0; r_insn[h] = '0;
            r_pc[h] = '0; r_x_wb[h] = '0; r_x_wdata[h] = '0;
            r_f_wb[h] = '0; r_f_wdata[h] = '0;
        end
        assign rvvi.valid[h][0]       = r_valid[h];
        assign rvvi.order[h][0]       = r_order[h];
        assign rvvi.insn[h][0]        = r_insn[h];
        assign rvvi.pc_rdata[h][0]    = r_pc[h];
        assign rvvi.x_wb[h][0]        = r_x_wb[h];
        assign rvvi.x_wdata[h][0]     = r_x_wdata[h];
        assign rvvi.trap[h][0]        = 1'b0;   // Vortex has no trap architecture
        assign rvvi.halt[h][0]        = 1'b0;
        assign rvvi.intr[h][0]        = 1'b0;
        assign rvvi.mode[h][0]        = 2'b11;  // M-mode only
        assign rvvi.ixl[h][0]         = 2'b01;  // XLEN=32
        assign rvvi.pc_wdata[h][0]    = '0;
        assign rvvi.f_wb[h][0]        = r_f_wb[h];
        assign rvvi.f_wdata[h][0]     = r_f_wdata[h];
        assign rvvi.v_wb[h][0]        = '0;
        assign rvvi.v_wdata[h][0]     = '0;
        assign rvvi.csr_wb[h][0]      = '0;
        assign rvvi.csr[h][0]         = '0;
        assign rvvi.lrsc_cancel[h][0] = 1'b0;
        assign rvvi.debug_mode[h][0]  = 1'b0;
    end
    assign rvvi.mode_virt = 1'b0;

    coverage #(ILEN, XLEN, FLEN, VLEN, NHART, RETIRE) cov;
    initial cov = new(rvvi);

    // Mode select. Default A (all active lanes); +ISACOV_MODE=B restricts to
    // lane 0. One elaboration serves both, so A and B are directly comparable
    // on an otherwise identical build.
    string isacov_mode = "A";
    initial begin
        string m;
        if ($value$plusargs("ISACOV_MODE=%s", m)) isacov_mode = m;
    end

    // One shim per core; only issue lane 0 of the commit arbiter is wired.
    // With ISSUE_WIDTH > 1 the other issue lanes need their own RETIRE slot;
    // that is a deliberate, stated gap, not a silent drop.
    wire retire_fire = commit_arb_if[0].valid && commit_arb_if[0].ready;

    longint unsigned n_shim_sampled = 0;   // liveness
    // Split writeback counters. These exist to make the FP routing OBSERVABLE:
    // the bug they were added to catch (rd is a unified register number) was
    // silent -- FP writebacks simply vanished and would have looked like a
    // stimulus gap in any future RV32F bank. A non-zero n_fp_wb on an FP kernel
    // is the direct evidence that f_wb/f_wdata are really being driven.
    longint unsigned n_int_wb = 0;
    longint unsigned n_fp_wb  = 0;

    always @(posedge clk) begin
        if (isacov_pkg::isacov_en && !reset && retire_fire) begin
            string d;
            logic [XLEN-1:0] pc;
            int base, h;
            pc   = to_fullPC(commit_arb_if[0].data.PC);
            d    = isacov_pkg::lookup(pc);
            base = int'(commit_arb_if[0].data.sid) * LANES;
            if (d.len() != 0) begin
                for (int l = 0; l < LANES; l++) begin
                    h = base + l;
                    if (h >= NHART) continue;
                    if (!commit_arb_if[0].data.tmask[l]) continue;   // inactive lane
                    if (isacov_mode == "B" && h != 0) continue;      // mode B: lane 0 only
                    r_pc[h]   = pc;
                    r_insn[h] = isacov_pkg::word_map.exists(pc) ? isacov_pkg::word_map[pc] : '0;
                    // Update the snapshot IN PLACE -- it must persist across
                    // retirements, so it is never cleared. x0 is hardwired zero
                    // and is excluded from the writeback flag.
                    //
                    // `rd` is a UNIFIED register number, not an architectural
                    // index: make_reg_num() packs it as (reg_type << RV_REGS_BITS)
                    // | idx (VX_gpu_pkg.sv:910), and REG_TYPES == 2 whenever the
                    // FPU is built (:41-45). Treating it as a plain index is
                    // wrong twice over -- `32'b1 << rd` sets NO bit once rd >= 32,
                    // and `x_wdata[rd]` is an out-of-range write that SystemVerilog
                    // discards in silence. The effect was not corruption but
                    // INVISIBILITY: every floating-point writeback was dropped, so
                    // an RV32F model would have scored zero and looked like a
                    // stimulus gap. Split the number properly and route F results
                    // to f_wb/f_wdata, which is what RVVI defines them for.
                    r_x_wb[h] = '0;
                    r_f_wb[h] = '0;
                    if (commit_arb_if[0].data.wb) begin
                        logic [RV_REGS_BITS-1:0] ridx;
                        ridx = commit_arb_if[0].data.rd[RV_REGS_BITS-1:0];
                        if (get_reg_type(commit_arb_if[0].data.rd) == REG_TYPE_F) begin
                            // f0 is a real register: no x0-style exclusion here.
                            r_f_wb[h] = (32'b1 << ridx);
                            r_f_wdata[h][ridx] = commit_arb_if[0].data.data[l][FLEN-1:0];
                            n_fp_wb++;
                        end else if (ridx != 0) begin
                            r_x_wb[h] = (32'b1 << ridx);
                            r_x_wdata[h][ridx] = commit_arb_if[0].data.data[l][XLEN-1:0];
                            n_int_wb++;
                        end
                    end
                    r_valid[h] = 1'b1;
                    r_order[h] = r_order[h] + 1;
                    cov.sample(1'b0, h, 0, d);
                    isacov_pkg::n_sampled++;
                    n_shim_sampled++;
                    r_valid[h] = 1'b0;
                end
            end
        end
    end

    final if (isacov_pkg::isacov_en)
        $display("[ISACOV] %m mode=%s NHART=%0d LANES=%0d sampled=%0d int_wb=%0d fp_wb=%0d",
                 isacov_mode, NHART, LANES, n_shim_sampled, n_int_wb, n_fp_wb);

endmodule : vortex_rvvi_shim
