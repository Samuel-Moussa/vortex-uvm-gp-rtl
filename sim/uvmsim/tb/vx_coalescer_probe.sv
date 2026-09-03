// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// File: vx_coalescer_probe.sv
// Description: PASSIVE memory-coalescing coverage probe (gap G-0).
//
// WHY THIS EXISTS
//   VX_mem_coalescer merges per-lane LSU requests into wider dcache-line
//   transactions -- the whole point of the SIMT memory path -- and had ZERO
//   functional coverage: no coverpoint anywhere observed whether a warp's
//   accesses actually coalesced, partially coalesced, or fully scattered.
//
// WHAT `misses` ACTUALLY MEANS (determined from VX_mem_coalescer.sv, not
// assumed):
//   `misses` (port, :41, width PERF_CTR_BITS=CLOG2(NUM_REQS+1)) is fed by
//   `misses_r`, a free-running counter (:332-344):
//       wire partial_transfer = (out_req_fire && req_rem_mask_r != '1);
//       always @(posedge clk) misses_r <= misses_r + partial_transfer;
//   i.e. it counts, CUMULATIVELY ACROSS THE WHOLE RUN, every output batch that
//   was NOT the first batch of its input request (req_rem_mask_r != '1 means
//   some lanes were already served by an earlier batch of the SAME request --
//   see the state machine at :201-224 and `is_last_batch` at :184). It is a
//   running total, NOT a saturating value and NOT per-request, so its raw port
//   value cannot be binned per-transaction directly.
//   This probe instead re-derives the SAME `partial_transfer` EVENT the RTL's
//   own counter is built from, but keyed PER INPUT REQUEST (reset every time
//   `in_req_ready` fires), which is exactly "how many extra output requests did
//   this one input request need" -- the per-transaction analogue of `misses`.
//   `misses` port itself is still wired in for documentation/citation but is
//   NOT stored in the covergroup (a running total has no per-bin meaning).
//   Note VX_mem_unit.sv:143 leaves `misses` as `` `UNUSED_PIN `` when
//   `` `ifndef PERF_ENABLE ``, but that only affects the EXTERNAL port
//   connection -- `misses_r` is computed UNCONDITIONALLY inside the module
//   (:332-344, no `` `ifdef ``), and `bind` gives full hierarchical visibility
//   into the bound module's internal signals regardless of how its ports were
//   externally connected. Verified by reading VX_mem_unit.sv:160-200: the
//   `` `ifdef PERF_ENABLE `` / `` `UNUSED_PIN `` split is entirely about the
//   port, never the internal logic.
//
// HOW THE PER-REQUEST BATCH COUNT IS DERIVED
//   `req_sent` (:243, `= (state_r == STATE_SEND)`) is high on the cycle a batch
//   is computed for send; `is_last_batch` (:184) is combinationally valid
//   during that same cycle and tells the state machine whether this batch
//   clears every masked lane. `in_req_ready` (:222, `in_req_ready_n =
//   is_last_batch` in the STATE_SEND branch) is therefore high iff
//   `req_sent && is_last_batch` -- exactly the handshake cycle the spec
//   requires sampling on (`in_req_valid && in_req_ready`).
//   `batch_count_r` here increments once per `(req_sent && !is_last_batch)`
//   cycle (a PRIOR partial transfer for the in-flight request) and is cleared
//   the cycle `is_last_batch` fires -- because clearing uses a nonblocking
//   assignment, `batch_count_r` still holds its PRE-clear value at the sample
//   point, i.e. the count of partial transfers this request needed BEFORE its
//   final batch. That value is 0 for a request that coalesced in one shot and
//   up to DATA_RATIO-1 for a request whose lanes never shared an address.
//
// WHERE IT BINDS
//   Into VX_mem_coalescer directly (bind VX_mem_coalescer ... in
//   vortex_tb_top.sv). VX_mem_unit.sv:160 instantiates it only when
//   `` (`NUM_LSU_LANES > 1) && (LSU_WORD_SIZE != DCACHE_WORD_SIZE) `` -- so the
//   bind is config-aware BY CONSTRUCTION exactly like vx_cache_probe: on a
//   config where lanes collapse 1:1 onto the dcache word (no coalescing to
//   do), no instance is elaborated and no bins are added, rather than an
//   unreachable 0% block needing a waiver. `NUM_LSU_BLOCKS` copies are
//   generated per VX_mem_unit.sv:161 `g_coalescers` loop, so multi-block
//   configs get one covergroup instance per block automatically.
//
// CONFIG-GENERIC
//   NUM_REQS / DATA_RATIO / OUT_REQS are the module's own elaborated
//   parameters, passed straight through by `bind` (which inherits the bound
//   instance's parameterization) -- never hardcoded. At the primary config
//   (1CL/1C/4W/4T, XLEN=32): NUM_REQS=4 (`NUM_LSU_LANES), DATA_RATIO=4
//   (DCACHE_WORD_SIZE=16 / LSU_WORD_SIZE=4), OUT_REQS=1.
//   DATA_RATIO > 1 is STRUCTURAL, not assumed: the module is only ever
//   instantiated when `LSU_WORD_SIZE != DCACHE_WORD_SIZE` (VX_mem_unit.sv:160)
//   and DCACHE_WORD_SIZE is always the wider of the two whenever they differ
//   (VX_gpu_pkg.sv:810 sizes it as MIN(NUM_LSU_LANES*(XLEN/8), L1_LINE_SIZE),
//   which is >= LSU_WORD_SIZE=XLENB whenever NUM_LSU_LANES>1), so
//   `DATA_RATIO = DATA_OUT_SIZE/DATA_IN_SIZE` is always >= 2 wherever this
//   probe is ever bound. The `cp_misses` bin range below relies on this.
//
// PASSIVE — NEVER A CHECKER
//   Observability only. Nothing here drives a signal or produces a pass/fail
//   verdict; the only checkers remain the end-state and lockstep comparisons.
////////////////////////////////////////////////////////////////////////////////

`ifndef VX_COALESCER_PROBE_SV
`define VX_COALESCER_PROBE_SV

module vx_coalescer_probe #(
    parameter string INSTANCE_ID  = "",
    parameter NUM_REQS            = 2,
    parameter DATA_RATIO          = 2,
    parameter OUT_REQS            = 1,
    parameter PERF_CTR_BITS       = 1
) (
    input wire clk,
    input wire reset,

    // The module's own free-running "misses" counter (see header). Wired in
    // for citation/traceability only -- NOT sampled directly (a running total
    // has no per-transaction bin meaning).
    input wire [PERF_CTR_BITS-1:0] misses,

    // Input-request handshake (VX_mem_coalescer.sv ports :44-52).
    input wire                     in_req_valid,
    input wire                     in_req_rw,
    input wire [NUM_REQS-1:0]      in_req_mask,
    input wire                     in_req_ready,

    // Internal state-machine signals (bind gives hierarchical read access):
    //   req_sent      = VX_mem_coalescer.sv:243 (state_r == STATE_SEND)
    //   is_last_batch = VX_mem_coalescer.sv:184
    input wire                     req_sent,
    input wire                     is_last_batch
);
    // `misses` is intentionally not consumed further -- see header. Reading it
    // here (even unused downstream) is what proves the bind sees the real
    // signal regardless of the `ifdef PERF_ENABLE` at the instantiation site.

    // -------------------------------------------------------------------
    // Per-request partial-transfer counter -- see header for the full
    // derivation. Cleared to 0 the cycle the request completes (NBA, so the
    // covergroup samples the PRE-clear value the same cycle).
    // -------------------------------------------------------------------
    int batch_count_r;

    always @(posedge clk) begin
        if (reset) begin
            batch_count_r <= 0;
        end else if (req_sent) begin
            batch_count_r <= is_last_batch ? 0 : (batch_count_r + 1);
        end
    end

    wire sample_en = in_req_valid && in_req_ready;

    // Active lanes in the request being retired this cycle.
    wire [$clog2(NUM_REQS+1)-1:0] c_active_lanes = $countones(in_req_mask);

    // Total output batches this request needed = prior partials + this one.
    wire is_full_coalesce = (batch_count_r == 0);
    wire is_full_scatter  = (c_active_lanes > 1) &&
                             ((batch_count_r + 1) == int'(c_active_lanes));
    // Coalescing category, GPU-relevant classification (the whole point of
    // gap G-0): does a warp's access collapse to one transaction (best case),
    // split into some-but-not-all-lanes-own-request (partial), or need one
    // output request per active lane (worst case, no coalescing benefit)?
    wire [1:0] coalesce_kind = is_full_coalesce ? 2'd0 :
                                is_full_scatter  ? 2'd2 : 2'd1;

    // -------------------------------------------------------------------
    // Covergroup. One instance per bound VX_mem_coalescer (per LSU block, per
    // core) -- option.per_instance keeps them separate in the UCDB hierarchy.
    // -------------------------------------------------------------------
    covergroup coalesce_cg @(posedge clk);
        option.per_instance = 1;
        option.name         = $sformatf("coalesce_cg_%s", INSTANCE_ID);

        // Read vs write.
        cp_rw : coverpoint in_req_rw iff (sample_en) {
            bins rd = {0};
            bins wr = {1};
        }

        // How many lanes were actually requesting this transaction.
        cp_active_lanes : coverpoint c_active_lanes iff (sample_en) {
            bins lanes[] = {[1 : NUM_REQS]};
        }

        // Per-request partial-transfer count -- the RTL's own `misses`
        // semantics (VX_mem_coalescer.sv:334 partial_transfer), applied
        // per-transaction instead of as a running total. 0 = fully coalesced
        // in a single output batch; DATA_RATIO-1 = the worst case (every
        // active lane in the group needed its own batch).
        cp_misses : coverpoint batch_count_r iff (sample_en) {
            bins fully_coalesced     = {0};
            bins partial_transfers[] = {[1 : DATA_RATIO-1]};
        }

        // FULL / PARTIAL / SCATTER classification -- the actual GPU-relevant
        // behaviour gap G-0 exists to close.
        cp_coalesce_kind : coverpoint coalesce_kind iff (sample_en) {
            bins full_coalesced = {0};
            bins partial        = {1};
            bins full_scatter   = {2};
        }

        cross_rw_lanes  : cross cp_rw, cp_active_lanes;
        cross_rw_misses : cross cp_rw, cp_misses;
    endgroup

    coalesce_cg cg_inst;

    initial begin
        cg_inst = new();
    end

endmodule

`endif // VX_COALESCER_PROBE_SV
