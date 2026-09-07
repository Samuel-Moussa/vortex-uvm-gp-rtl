// =============================================================================
// vx_lmem_probe.sv  —  G-9: LMEM (scratchpad) bank-conflict coverage
//
// HOW IT BINDS (passive, no DUT edits):
//   bind VX_local_mem vx_lmem_probe #(
//       .NUM_REQS(NUM_REQS), .NUM_BANKS(NUM_BANKS)
//   ) u_lmem_probe (
//       .clk(clk), .reset(reset),
//       .req_bank_idx(req_bank_idx), .mem_bus_if(mem_bus_if)
//   );
// NUM_REQS/NUM_BANKS/req_bank_idx/mem_bus_if are the bound instance's OWN
// elaborated parameters/signals, passed through explicitly at the bind call
// site (same pattern as vx_coalescer_probe on VX_mem_coalescer) rather than
// referenced as bare identifiers -- unlike an interface-member or
// generate-block-member access (vx_hazard_probe's technique on VX_scoreboard),
// a bare module-local parameter/wire is NOT resolvable by Questa's vlog pass
// until elaboration, so it must come in through the port/parameter list.
//
// req_bank_idx is the RTL's OWN bank-select decode (VX_local_mem.sv:65-71,
// `mem_bus_if[i].req_data.addr[0 +: BANK_SEL_BITS]`) — reused as-is, never
// re-derived, so this can never disagree with what the hardware actually does.
//
// A "conflict" is >=2 of this cycle's OFFERED (req_valid alone, NOT
// req_valid && req_ready) per-lane requests mapping to the SAME bank -- i.e.
// arbitration PRESSURE, not simultaneous acceptance. OBS-060
// (docs/RTL_OBSERVATIONS.md): the RTL's own crossbar (VX_local_mem.sv
// instantiates VX_stream_xbar with NUM_OUTPUTS=NUM_BANKS, and
// VX_stream_xbar.sv declares exactly one valid_out/data_out per OUTPUT port)
// can structurally accept at most ONE winner per bank per cycle -- so
// gating this bin on req_ready made "2+ accepted same bank same cycle" a
// logical impossibility, not a rare stimulus event, and the bin could never
// go non-zero no matter how bank-hostile the access pattern was (measured:
// idle=70498, no_conflict=192, conflict=0 under deliberate 4-way same-bank
// contention). Reclassifying on req_valid alone measures the real,
// reachable property this plan item wants: did 2+ lanes WANT the same bank
// this cycle, whether or not the arbiter picked a winner -- exactly the
// scratchpad contention `lmem_stress` is meant to stress (plan G-9).
//
// Read-only by discipline: `mem_bus_if` takes the `.slave` modport (matching
// VX_local_mem's own role) purely so this module can READ req_valid/
// req_data/rsp_ready; it never assigns req_ready/rsp_valid/rsp_data, exactly
// the same discipline vx_instr_probe documents for dispatch_if.
// =============================================================================
module vx_lmem_probe #(
    parameter NUM_REQS  = 4,
    parameter NUM_BANKS = 4
) (
    input wire clk,
    input wire reset,
    input wire [NUM_REQS-1:0][(NUM_BANKS > 1 ? $clog2(NUM_BANKS) : 1)-1:0] req_bank_idx,
    VX_mem_bus_if.slave mem_bus_if [NUM_REQS]
);

    typedef enum { LMEM_IDLE, LMEM_NO_CONFLICT, LMEM_CONFLICT } lmem_conflict_e;

    covergroup lmem_bank_cg with function sample(lmem_conflict_e conflict_class);
        option.per_instance = 1;
        option.name         = "lmem_bank_cg";

        cp_bank_conflict : coverpoint conflict_class {
            bins idle        = { LMEM_IDLE };        // no request offered this cycle
            bins no_conflict = { LMEM_NO_CONFLICT };  // requests offered, all distinct banks
            bins conflict    = { LMEM_CONFLICT };     // >=2 requests offered, same bank (OBS-060: offered, not accepted)
        }
    endgroup

    lmem_bank_cg cg_lmem = new();

    // Interface INSTANCE ARRAYS require a constant (genvar) index -- a plain
    // `for` loop variable is rejected by elaboration. Extract the one bit per
    // lane this probe needs into a flat vector here (generate context), then
    // do the actual aggregation below on ordinary arrays with a runtime loop.
    //
    // OBS-060: this is req_valid ALONE (offered), not req_valid && req_ready
    // (accepted) -- see the header comment. Using req_ready here would make
    // cp_bank_conflict.conflict structurally unreachable, since the RTL's
    // own crossbar (VX_stream_xbar, NUM_OUTPUTS=NUM_BANKS) can accept at
    // most one winner per bank per cycle by construction.
    wire [NUM_REQS-1:0] lane_offer;
    for (genvar i = 0; i < NUM_REQS; i++) begin : g_lane_offer
        assign lane_offer[i] = mem_bus_if[i].req_valid;
    end

    always @(posedge clk) begin
        if (!reset) begin
            automatic int unsigned bank_count [NUM_BANKS];
            automatic bit          any_active;
            automatic bit          any_conflict;
            any_active   = 1'b0;
            any_conflict = 1'b0;
            for (int b = 0; b < NUM_BANKS; b++) bank_count[b] = 0;
            for (int i = 0; i < NUM_REQS; i++) begin
                if (lane_offer[i]) begin
                    any_active = 1'b1;
                    bank_count[req_bank_idx[i]]++;
                    if (bank_count[req_bank_idx[i]] > 1) any_conflict = 1'b1;
                end
            end
            cg_lmem.sample(!any_active ? LMEM_IDLE :
                            any_conflict ? LMEM_CONFLICT : LMEM_NO_CONFLICT);
        end
    end

endmodule : vx_lmem_probe
