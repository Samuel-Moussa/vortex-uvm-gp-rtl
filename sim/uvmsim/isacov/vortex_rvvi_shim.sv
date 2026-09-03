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
// OPTION B (this file): hart = core, and only SIMD LANE 0 (thread 0) is
// sampled.  Rationale from the handover: start where a miscompare is
// attributable.  Lane 0 is the lane that always exists -- vx_start.S:41-42
// boots with tmask = 1 -- so it can never be an inactive lane whose register
// values are undefined.  Option A (lane-as-hart, NHART = threads) is the next
// step and needs tmask suppression or coverage inflates silently.
//
// WHAT DRIVES THE MODEL
//   riscvISACOV keys on DISASSEMBLY TEXT, not on the instruction word
//   (RISCV_coverage_base.svh:1381).  The text comes from isacov_pkg's static
//   PC->text map built by gen_disass_map.sh from the kernel's own objdump.
//   A PC with no map entry yields "" which matches no covergroup -- that is the
//   correct behaviour for Vortex custom ops, which objdump renders as `.insn`.
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
    localparam int ILEN=32, XLEN=32, FLEN=32, VLEN=256, NHART=1, RETIRE=1;

    rvviTrace #(ILEN, XLEN, FLEN, VLEN, NHART, RETIRE) rvvi();

    logic                  r_valid   = 1'b0;
    logic [63:0]           r_order   = '0;
    logic [ILEN-1:0]       r_insn    = '0;
    logic [XLEN-1:0]       r_pc      = '0;
    logic [31:0]           r_x_wb    = '0;
    logic [31:0][XLEN-1:0] r_x_wdata = '0;

    assign rvvi.clk               = clk;
    assign rvvi.valid[0][0]       = r_valid;
    assign rvvi.order[0][0]       = r_order;
    assign rvvi.insn[0][0]        = r_insn;
    assign rvvi.pc_rdata[0][0]    = r_pc;
    assign rvvi.x_wb[0][0]        = r_x_wb;
    assign rvvi.x_wdata[0][0]     = r_x_wdata;
    assign rvvi.trap[0][0]        = 1'b0;      // Vortex has no trap architecture
    assign rvvi.halt[0][0]        = 1'b0;
    assign rvvi.intr[0][0]        = 1'b0;
    assign rvvi.mode[0][0]        = 2'b11;     // M-mode only
    assign rvvi.ixl[0][0]         = 2'b01;     // XLEN=32
    assign rvvi.pc_wdata[0][0]    = '0;
    assign rvvi.f_wb[0][0]        = '0;
    assign rvvi.f_wdata[0][0]     = '0;
    assign rvvi.v_wb[0][0]        = '0;
    assign rvvi.v_wdata[0][0]     = '0;
    assign rvvi.csr_wb[0][0]      = '0;
    assign rvvi.csr[0][0]         = '0;
    assign rvvi.lrsc_cancel[0][0] = 1'b0;
    assign rvvi.debug_mode[0][0]  = 1'b0;
    assign rvvi.mode_virt         = 1'b0;

    coverage #(ILEN, XLEN, FLEN, VLEN, NHART, RETIRE) cov;
    initial cov = new(rvvi);

    // One shim per core; only issue lane 0 is wired.  With ISSUE_WIDTH > 1 the
    // remaining lanes are deliberately not sampled yet -- they need their own
    // rvviTrace slot (RETIRE > 1), which is Option A work, not a silent drop.
    wire retire_fire = commit_arb_if[0].valid && commit_arb_if[0].ready;

    longint unsigned n_shim_sampled = 0;   // liveness

    always @(posedge clk) begin
        if (isacov_pkg::isacov_en && !reset && retire_fire
                && commit_arb_if[0].data.sop            // one sample per instruction
                && commit_arb_if[0].data.tmask[0]) begin // lane 0 actually active
            string d;
            r_pc      = to_fullPC(commit_arb_if[0].data.PC);
            d         = isacov_pkg::lookup(r_pc);
            r_insn    = isacov_pkg::word_map.exists(r_pc) ? isacov_pkg::word_map[r_pc] : '0;
            r_x_wdata = '0;
            r_x_wb    = '0;
            if (commit_arb_if[0].data.wb && commit_arb_if[0].data.rd != 0) begin
                r_x_wb = (32'b1 << commit_arb_if[0].data.rd);
                r_x_wdata[commit_arb_if[0].data.rd] = commit_arb_if[0].data.data[0][XLEN-1:0];
            end
            r_valid = 1'b1;
            r_order = r_order + 1;
            if (d.len() != 0) begin
                cov.sample(1'b0, 0, 0, d);
                isacov_pkg::n_sampled++;
                n_shim_sampled++;
            end
            r_valid = 1'b0;
        end
    end

endmodule : vortex_rvvi_shim
