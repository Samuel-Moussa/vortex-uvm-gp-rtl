// =============================================================================
// vx_hazard_probe.sv  —  Register-hazard functional coverage (gap G-4)
//
// Plan item: ISS-2 "Register hazards (RAW/WAW/WAR)" — VX_scoreboard.sv is real
// in-use-register hazard-detection logic with NO functional coverage anywhere
// (L2 has none; L1's REG_HAZARD only exists at riscvISACOV's unused EXTENDED
// level). Black-box / observe-only.
//
// HOW IT BINDS (passive, no DUT edits):
//   bind VX_scoreboard vx_hazard_probe u_hazard_probe ( .clk(clk), .reset(reset) );
// One probe per VX_scoreboard instance (i.e. per issue slot per core). The
// signals this probe needs — `operands_busy` and `staging_if[w]` — live INSIDE
// VX_scoreboard's own `g_scoreboard[w]` generate block, not at its port list,
// so rather than hoist them to new flat ports (an RTL edit) this probe walks
// them by their existing hierarchical names from its own per-warp generate
// loop. A bind places a module in the target's scope with full visibility of
// the target's internals, so `g_scoreboard[w].operands_busy` and
// `staging_if[w]` (declared flat, outside the generate, VX_scoreboard.sv:40)
// resolve exactly as if this code were pasted into VX_scoreboard's body.
//
// WHAT operands_busy MEANS (confirmed by reading VX_scoreboard.sv:122-175):
//   Per warp w, per operand slot i in {0:rd, 1:rs1, 2:rs2, 3:rs3},
//   operands_busy[i] means "this operand's register is currently reserved by
//   an earlier, not-yet-written-back instruction from the SAME warp."
//   inuse_regs only ever reserves a register on its PRODUCER's rd
//   (VX_scoreboard.sv:152/155 — "reserve rd" / "release rd") — a source read
//   is never reserved. Combined with strictly in-order per-warp issue, this
//   means WAR (write-after-read) is STRUCTURALLY UNREACHABLE in this design:
//   there is no code path that could ever produce one. So this probe covers
//   RAW and WAW only — cp_hazard_type has no WAR bin, and that omission is a
//   verified finding, not an oversight (see the ignore_bins comment below).
//
// SAMPLING (approximate by design, honestly documented):
//   operands_busy is combinational; the actual issue-gating operands_ready[w]
//   is a ONE-CYCLE-REGISTERED version of ~(|regs_busy) (VX_scoreboard.sv:185),
//   so there is up to a 1-cycle skew between the sampled operands_busy and the
//   exact cycle a given stall/issue decision used. This probe classifies
//   hazard TYPE for functional coverage (was this warp ever exposed to a RAW
//   / WAW register conflict, and which operand), not a cycle-exact checker —
//   inuse_regs itself only changes on a clocked writeback/reservation event,
//   so the hazard TYPE is stable for the whole stall duration regardless of
//   which cycle within it gets sampled.
// =============================================================================

module vx_hazard_probe import VX_gpu_pkg::*; #(
    parameter CORE_ID = 0
) (
    input wire clk,
    input wire reset
);

    // ---- Config-derived widths (robust, no macros) --------------------------
    localparam int NUM_OPDS_L = NUM_SRC_OPDS + 1;   // rd, rs1, rs2, rs3

    // =========================================================================
    // Register-hazard type, per warp, per staged instruction.
    // =========================================================================
    covergroup hazard_cg with function sample(
        int unsigned wid,
        logic        rd_busy,
        logic        rs1_busy,
        logic        rs2_busy,
        logic        rs3_busy
    );
        option.per_instance = 1;
        option.name = "reg_hazard_cg";

        // Explicitly bounded — PER_ISSUE_WARPS is small (a handful at most),
        // and wid is `int unsigned` so Questa's default auto-binning spreads
        // it across 64 buckets of the full 32-bit range instead of one bin
        // per real warp; an explicit range fixes that regardless of config.
        cp_wid : coverpoint wid {
            bins w[] = { [0 : PER_ISSUE_WARPS-1] };
        }

        // Classic hazard-type classification. WAW = this instruction's own rd
        // collides with an in-flight producer's rd. RAW = any source operand
        // collides with an in-flight producer's rd. Both can fire together.
        // WAR has no bin: inuse_regs never reserves a source register
        // (VX_scoreboard.sv:152/155 reserves rd only), and per-warp issue is
        // strictly in-order, so a write can never chase an earlier read on the
        // same warp — WAR is provably unreachable here, not merely unobserved.
        cp_hazard_type : coverpoint {rd_busy, (rs1_busy || rs2_busy || rs3_busy)} {
            bins none         = { 2'b00 };
            bins raw_only     = { 2'b01 };
            bins waw_only     = { 2'b10 };
            bins raw_and_waw  = { 2'b11 };
        }

        cross_wid_hazard : cross cp_wid, cp_hazard_type;
    endgroup

    hazard_cg u_hazard = new();

    // =========================================================================
    // Sampling — one generate iteration per issue-warp, referencing
    // VX_scoreboard's own internal per-warp generate block and its flat
    // staging_if array by their existing names (see file header).
    // =========================================================================
    for (genvar w = 0; w < PER_ISSUE_WARPS; ++w) begin : g_hazard_sample
        always @(posedge clk) begin
            if (!reset && staging_if[w].valid) begin
                u_hazard.sample(
                    w,
                    g_scoreboard[w].operands_busy[0],
                    g_scoreboard[w].operands_busy[1],
                    g_scoreboard[w].operands_busy[2],
                    g_scoreboard[w].operands_busy[3]
                );
            end
        end
    end

endmodule : vx_hazard_probe
