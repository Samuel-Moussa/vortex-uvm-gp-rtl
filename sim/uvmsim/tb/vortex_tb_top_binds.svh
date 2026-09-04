// Copyright (c) 2026 -- Vortex UVM GP.
// SPDX-License-Identifier: Apache-2.0
//
// Passive coverage/observability probe binds.
// CRITICAL: these MUST elaborate inside an instantiated scope. A file-scope
// bind lands in an uninstantiated $unit and is SILENTLY DROPPED -- the run
// passes with zero coverage and no error. That is why this is an `include`
// fragment inside vortex_tb_top and not a separate module.
// Extracted verbatim from vortex_tb_top.sv (no logic change).
//
// ---------------------------------------------------------------------------
// THIS IS AN `include` FRAGMENT, NOT A COMPILATION UNIT.
// It is textually included INSIDE the body of `vortex_tb_top` (tb/vortex_tb_top.sv).
// It must NOT be added to any .flist as a standalone file: Questa is
// single-file-compilation-unit (no -mfcu), so a file that is BOTH `include`-d
// and listed standalone compiles a second time into a $unit package nothing
// can reference (vlog-13233). That defect was found and removed in 59b7ea2 --
// do not reintroduce it. Reach this file with +incdir+ only.
// ---------------------------------------------------------------------------

    end


    // Bind warp/scheduler-state coverage probe into every VX_schedule instance
    bind VX_schedule vx_sched_probe #(.CORE_ID(0)) u_sched_probe (
        .clk          (clk),
        .reset        (reset),
        .warp_ctl_if  (warp_ctl_if),
        .schedule_if  (schedule_if),
        .active_warps (active_warps),
        .stalled_warps(stalled_warps),
        .barrier_ctrs (barrier_ctrs),
        .join_valid   (join_valid),
        .join_is_dvg  (join_is_dvg),
        .join_is_else (join_is_else),
        .join_tmask   (join_tmask)
    );

    // G-4-bind: passive register-hazard coverage probe into every VX_scoreboard
    // instance (one per issue slot per core). Only clk/reset are connected --
    // the probe reaches operands_busy/staging_if by their own hierarchical
    // names from VX_scoreboard's internal g_scoreboard[] generate block and
    // flat staging_if[] array (see vx_hazard_probe.sv header for why: those
    // signals are generate-scoped, not module ports, and a bind places the
    // probe directly in VX_scoreboard's own scope with full visibility).
    bind VX_scoreboard vx_hazard_probe u_hazard_probe (
        .clk  (clk),
        .reset(reset)
    );

    // Bind white-box instruction probe into every VX_dispatch instance
    bind VX_dispatch vx_instr_probe #(.CORE_ID(0)) u_instr_probe (
        .clk        (clk),
        .reset      (reset),
        .dispatch_if(dispatch_if)
    );

    // P1-bind: passive commit/retire probe into every VX_commit instance
    // (observability only; Ahmad samples commit_arb_if for coverage).
    bind VX_commit vx_commit_probe u_commit_probe (
        .clk          (clk),
        .reset        (reset),
        .commit_arb_if(commit_arb_if)
    );

    // B1-bind: passive per-core DCR register observer. VX_core.sv:82 instantiates
    // VX_dcr_data once per core, so this creates exactly one probe per core the
    // config actually built — config-aware by construction, no path enumeration.
    // Supplies the READ side the write-only VX_dcr_bus_if cannot, turning the RAL
    // mirror into a real check. PEEK ONLY: it never drives, so the DCR waveform
    // (and therefore the SimX feed at vortex_scoreboard.sv:403) is unchanged.
    // Note the connection to `dcrs`, the module's INTERNAL storage register.
    bind VX_dcr_data vx_dcr_probe u_dcr_probe (
        .clk         (clk),
        .reset       (reset),
        .write_valid (dcr_bus_if.write_valid),
        .write_addr  (dcr_bus_if.write_addr),
        .write_data  (dcr_bus_if.write_data),
        .dcrs        (dcrs)
    );

    // A1(d)-bind: passive LOAD-writeback probe into every VX_lsu_slice. Captures
    // the final aligned per-lane load DATA (result_if) — invisible at the commit
    // tap (OBS-002) — so lockstep can DATA-compare loads. +LOCKSTEP-gated, passive.
    bind VX_lsu_slice vx_lsu_probe u_lsu_probe (
        .clk  (clk),
        .reset(reset),
        .valid(result_if.valid),
        .ready(result_if.ready),
        .data (result_if.data)
    );

    // FW-6 / gap G1: passive CACHE-EVENT coverage probe, bound into every
    // VX_cache_bank (the stage where hit/miss is actually resolved). One instance
    // per bank per cache, so L1 I$/D$, L2 and L3 land as SEPARATE covergroup
    // instances in the UCDB hierarchy.
    //
    // CONFIG-AWARE BY CONSTRUCTION: VX_cache_wrap.sv:160 instantiates VX_cache —
    // and hence VX_cache_bank — only when `PASSTHRU == 0`. With L2/L3 disabled
    // those levels are pure bypass, no bank exists, so this bind creates NO
    // instance and adds NO bins. That means the default (L2/L3-off) build keeps
    // its coverage denominator untouched and there is no unreachable 0% block to
    // waive — the failure mode that made the TCU covergroup a dead ~195-bin block
    // before it was gated. Cache geometry is passed through from the bank's own
    // parameters, never restated here (the OBS-019 single-source-of-truth rule).
    bind VX_cache_bank vx_cache_probe #(
        .INSTANCE_ID(INSTANCE_ID),
        .BANK_ID    (BANK_ID),
        .CACHE_SIZE (CACHE_SIZE),
        .NUM_WAYS   (NUM_WAYS),
        .WRITEBACK  (WRITEBACK),
        // Structural waiver key: the icache is built .WRITE_ENABLE(0)
        // (VX_socket.sv:106), which makes its write and flush bins impossible
        // rather than unstimulated. Passed through by `bind` so the waiver is
        // per-instance and config-generic -- enable L2/L3 or change the socket
        // and the correct caches keep their bins with no edit here.
        .WRITE_ENABLE (WRITE_ENABLE),
        // OBS-031 structural-reachability key for cp_mshr_stall.stall. The bin
        // needs MSHR_SIZE CONCURRENT outstanding misses in one bank; whether
        // that is possible is set by the REQUESTER side, which is narrower than
        // the MSHR at L1 in this configuration. Computed HERE because the
        // VX_config.vh macros are in scope at the bind site but not inside the
        // probe, and passed per-instance so it adapts to any config.
        //   L1 icache: at most one outstanding fetch per warp, over the cores
        //              sharing the socket.
        //   L1 dcache: LSUQ_OUT_SIZE outstanding memory requests per LSU, over
        //              the cores sharing the socket (VX_config.vh:431).
        //   anything else (L2 1 MB / L3 2 MB): the requesters are CACHES, not a
        //              core pipeline, and that bound is NOT established here —
        //              so fall back to MSHR_SIZE, which makes the waiver
        //              inapplicable. Never guess a bound for a level we have not
        //              analysed; an unproven ignore_bins is the OBS-030 failure.
        // ICACHE_SIZE == DCACHE_SIZE (both 16384), so WRITE_ENABLE is what
        // separates them (the icache is built .WRITE_ENABLE(0), VX_socket.sv:106).
        .MSHR_SIZE (MSHR_SIZE),
        .MAX_OUTSTANDING (
            (CACHE_SIZE == `ICACHE_SIZE && WRITE_ENABLE == 0)
                ? (`SOCKET_SIZE * `NUM_WARPS)
          : (CACHE_SIZE == `DCACHE_SIZE && WRITE_ENABLE == 1)
                ? (`SOCKET_SIZE * `LSUQ_OUT_SIZE)
          : MSHR_SIZE)
    ) u_cache_probe (
        .clk            (clk),
        .reset          (reset),
        .valid_st1      (valid_st1),
        .is_creq_st1    (is_creq_st1),
        .is_fill_st1    (is_fill_st1),
        .is_flush_st1   (is_flush_st1),
        .is_replay_st1  (is_replay_st1),
        .is_hit_st1     (is_hit_st1),
        .rw_st1         (rw_st1),
        .is_dirty_st1   (is_dirty_st1),
        .perf_read_miss (perf_read_miss),
        .perf_write_miss(perf_write_miss),
        .perf_mshr_stall(perf_mshr_stall)
    );

    // Gap G-0: passive MEMORY-COALESCING coverage probe, bound directly into
    // VX_mem_coalescer. VX_mem_unit.sv:160 instantiates the coalescer only
    // when `` (`NUM_LSU_LANES > 1) && (LSU_WORD_SIZE != DCACHE_WORD_SIZE) `` --
    // config-aware BY CONSTRUCTION, same principle as the cache probe above:
    // a config where lanes map 1:1 onto the dcache word elaborates no
    // instance and adds no bins, rather than leaving an unreachable block to
    // waive. NUM_REQS/DATA_RATIO/OUT_REQS are the bound instance's OWN
    // elaborated parameters (bind inherits them), never restated here. See
    // vx_coalescer_probe.sv header for the full `misses` semantics derivation.
    bind VX_mem_coalescer vx_coalescer_probe #(
        .INSTANCE_ID   (INSTANCE_ID),
        .NUM_REQS      (NUM_REQS),
        .DATA_RATIO    (DATA_RATIO),
        .OUT_REQS      (OUT_REQS),
        .PERF_CTR_BITS (PERF_CTR_BITS)
    ) u_coalescer_probe (
        .clk           (clk),
        .reset         (reset),
        .misses        (misses),
        .in_req_valid  (in_req_valid),
        .in_req_rw     (in_req_rw),
        .in_req_mask   (in_req_mask),
        .in_req_ready  (in_req_ready),
        .req_sent      (req_sent),
        .is_last_batch (is_last_batch)
    );

`ifdef ISACOV
    // ---- riscvISACOV bank (opt-in: compiled only when ISACOV=1) ------------
    // Independent third-party RV32I ISA functional-coverage model (Imperas,
    // Apache-2.0, used UNMODIFIED from third_party/riscvISACOV).
    // These binds MUST live inside this module. A bind at file scope sits in a
    // $unit that nothing instantiates, so Questa never elaborates it and the
    // binds are silently dropped -- measured, not assumed: the first
    // integration run passed cleanly and produced ZERO [ISACOV] output. Placing
    // them here keeps vortex_tb_top the single elaboration top.
    //
    // Both probes are strictly passive and both are additionally gated at
    // runtime by +ISACOV, so an ISACOV=1 build without the plusarg is still
    // byte-identical to a default run.

    // Fetch-stage instruction-word observer. Cross-checks the objdump-derived
    // disassembly map against the words the DUT actually fetched, so a stale
    // ELF cannot silently fabricate ISA coverage.
    bind VX_fetch vx_instr_word_probe u_instr_word_probe (
        .clk     (clk),
        .reset   (reset),
        .fetch_if(fetch_if)
    );

    // Retirement -> RVVI-TRACE -> riscvISACOV. One model per core; lane-as-hart
    // by default (+ISACOV_MODE=B for lane 0 only).
    bind VX_commit vortex_rvvi_shim u_rvvi_shim (
        .clk          (clk),
        .reset        (reset),
        .commit_arb_if(commit_arb_if)
    );
`endif


