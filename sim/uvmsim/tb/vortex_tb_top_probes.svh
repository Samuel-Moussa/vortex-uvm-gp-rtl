// Copyright (c) 2026 -- Vortex UVM GP.
// SPDX-License-Identifier: Apache-2.0
//
// Testbench status tracking + deep RTL pipeline-stage debug probes.
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

    //==========================================================================
    // TESTBENCH STATUS TRACKING (Required for virtual interface metrics)
    //==========================================================================

    logic [63:0] tb_cycle_count;
    logic [63:0] tb_instr_count;
    logic [63:0] tb_mem_ops;
    logic        tb_execution_started;
    logic        tb_execution_complete;
    int          tb_idle_cycles;
    int          tb_busy_low_cycles;     // Issue 2: consecutive cycles with busy==0
    logic        tb_probe_ebreak_seen;   // C3: registered — set when ebreak first seen at fetch
    wire         tb_ebreak_fetch;        // C3: combinational — OR across all cores

    // I1: multi-core commit + ebreak observation arrays.
    // One wire per commit lane (NUM_CLUSTERS × NUM_SOCKETS × SOCKET_SIZE × ISSUE_WIDTH).
    // One wire per core for ebreak detection.
    localparam TB_NUM_CLUSTERS = `NUM_CLUSTERS;
    localparam TB_NUM_SOCKETS  = VX_gpu_pkg::NUM_SOCKETS;
    localparam TB_SOCK_SIZE    = `SOCKET_SIZE;
    localparam TB_ISSUE_W      = `ISSUE_WIDTH;
    localparam TB_NUM_CORES_T  = TB_NUM_CLUSTERS * TB_NUM_SOCKETS * TB_SOCK_SIZE;
    localparam TB_NUM_LANES    = TB_NUM_CORES_T * TB_ISSUE_W;

    wire [TB_NUM_LANES-1:0]   tb_commit_fires_all;  // per-lane commit handshake
    wire [TB_NUM_CORES_T-1:0] tb_ebreak_fetch_all;  // per-core ebreak-at-fetch
    logic [$clog2(TB_NUM_LANES+1)-1:0] tb_commit_count_cyc; // popcount this cycle

    // Popcount: how many lanes committed this clock edge
    always_comb begin : u_commit_popcount
        tb_commit_count_cyc = '0;
        for (int _i = 0; _i < TB_NUM_LANES; _i++)
            tb_commit_count_cyc += TB_NUM_LANES'(tb_commit_fires_all[_i]);
    end
    assign tb_ebreak_fetch = |tb_ebreak_fetch_all;

    int idle_threshold_val = 5000;
    // Issue 2 fix: busy=0 completion must be SUSTAINED, not a single-cycle glitch.
    // A transient busy de-assertion between kernel phases must NOT end the test.
    int busy_low_threshold_val = 100;
    initial begin
        int tmp;
        if ($value$plusargs("IDLE_THRESHOLD=%d", tmp))     idle_threshold_val     = tmp;
        if ($value$plusargs("BUSY_LOW_THRESHOLD=%d", tmp)) busy_low_threshold_val = tmp;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            tb_cycle_count        <= 0;
            tb_instr_count        <= 0;
            tb_mem_ops            <= 0;
            tb_execution_started  <= 0;
            tb_execution_complete <= 0;
            tb_idle_cycles        <= 0;
            tb_busy_low_cycles    <= 0;
        end else begin
            tb_cycle_count <= tb_cycle_count + 1;

            // I1/C2: real retired count — sum all commit lanes across all cores
            tb_instr_count <= tb_instr_count + 64'(tb_commit_count_cyc);

            // Issue 2: track SUSTAINED busy de-assertion. Reset on any busy-high
            // cycle so a transient gap can never accumulate to the threshold.
            if (tb_execution_started && !tb_execution_complete && !vif.status_if.busy)
                tb_busy_low_cycles <= tb_busy_low_cycles + 1;
            else
                tb_busy_low_cycles <= 0;

            if ((vif.axi_if.rvalid && vif.axi_if.rready) ||
                (vif.axi_if.bvalid && vif.axi_if.bready) ||
                (vif.mem_if.req_valid[0] && vif.mem_if.req_ready[0])) begin
                tb_mem_ops     <= tb_mem_ops + 1;
                tb_idle_cycles <= 0;
                if (!tb_execution_started) begin
                    tb_execution_started <= 1;
                    $display("\n[TB_STATUS @ %0t] Execution STARTED", $time);
                end
            end else if (tb_execution_started && !tb_execution_complete) begin
                // PROGRESS is instruction retirement, not just memory activity. A
                // compute-bound kernel (long ALU loop, no memory ops) is busy and
                // making progress -> it must NOT count as idle, else the idle
                // safety net (below) cuts it short mid-compute (was the root cause
                // of compute-kernel thread-0-only failures: the tail stores never
                // executed). Reset the hang counter on any commit this cycle.
                if (tb_commit_count_cyc != 0)
                    tb_idle_cycles <= 0;
                else
                    tb_idle_cycles <= tb_idle_cycles + 1;
            end

            // C3 PRIMARY: ebreak (0x00100073) decoded at fetch stage
            // tb_ebreak_fetch is combinational (same-cycle); tb_probe_ebreak_seen is registered
            // (latched one cycle earlier) — either fires the primary path.
            if (tb_execution_started && !tb_execution_complete && (tb_ebreak_fetch || tb_probe_ebreak_seen)) begin
                tb_execution_complete <= 1;
                $display("\n╔═══════════════════════════════════════════════════╗");
                $display("║  EXECUTION COMPLETE (ebreak 0x00100073 decoded)  ║");
                $display("╚═══════════════════════════════════════════════════╝");
                $display("  Total Cycles: %0d  Mem Ops: %0d  Instructions: %0d",
                         tb_cycle_count, tb_mem_ops, tb_instr_count);
            // C3 FALLBACK 1: SUSTAINED busy=0 without ebreak — should not happen in a
            // correct run. Issue 2 fix: require busy low for busy_low_threshold_val
            // consecutive cycles so a transient mid-kernel gap can't end the test early.
            end else if (tb_execution_started && !tb_execution_complete &&
                         tb_busy_low_cycles >= busy_low_threshold_val) begin
                tb_execution_complete <= 1;
                $display("\n** Warning: [TB_TOP @ %0t] EXECUTION COMPLETE via sustained busy=0 fallback (%0d cyc) — ebreak not decoded",
                         $time, busy_low_threshold_val);
                $display("  Total Cycles: %0d  Mem Ops: %0d  Instructions: %0d",
                         tb_cycle_count, tb_mem_ops, tb_instr_count);
            // C3 FALLBACK 2: idle threshold — program may be hung
            end else if (tb_execution_started && !tb_execution_complete &&
                         tb_idle_cycles >= idle_threshold_val) begin
                tb_execution_complete <= 1;
                $display("\n** Warning: [TB_TOP @ %0t] EXECUTION COMPLETE via idle safety net (%0d cyc) — ebreak not decoded",
                         $time, idle_threshold_val);
                $display("  DUT busy=%b — may be stuck!", vif.status_if.busy);
            end
        end
    end

    // Safely handle idle channel detection regardless of wrapper
    `ifdef USE_AXI_WRAPPER
        wire axi_channels_idle = !vif.axi_if.rvalid  && !vif.axi_if.arvalid &&
                                  !vif.axi_if.awvalid && !vif.axi_if.wvalid &&
                                  !vif.axi_if.bvalid;
        wire mem_channels_idle = 1'b1;
    `else
        wire axi_channels_idle = 1'b1;
        wire mem_channels_idle = !vif.mem_if.req_valid[0] && !vif.mem_if.rsp_valid[0];
    `endif
    
    assign vif.status_if.ebreak_detected = tb_execution_complete && axi_channels_idle && mem_channels_idle;
    assign vif.status_if.cycle_count     = tb_cycle_count;
    assign vif.status_if.instr_count     = tb_instr_count;
    // Real fetched-instruction PC (core[0]) so cp_pc_region samples the actual
    // program text region instead of a constant 0 (was hardcoded 0 -> cp_pc_region
    // 0% ZERO). tb_status_pc is driven from fetch_pc_full inside each ifdef branch
    // of the pipeline-probe block below (declared here at module scope).
    wire [31:0] tb_status_pc;
    assign vif.status_if.pc              = tb_status_pc;
    // Pipeline stall flags for cp_fetch_stall / cp_memory_stall (driven from the
    // icache/dcache req-stall probes inside each ifdef branch below; core[0]).
    wire tb_fetch_stall, tb_memory_stall;
    assign vif.status_if.fetch_stall     = tb_fetch_stall;
    assign vif.status_if.memory_stall    = tb_memory_stall;
    // Pipeline backpressure stalls for cp_decode/issue/execute_stall (driven from
    // fetch_if/decode_if/dispatch_if valid&&!ready probes in each ifdef branch; core[0]).
    wire tb_decode_stall, tb_issue_stall, tb_execute_stall;
    assign vif.status_if.decode_stall    = tb_decode_stall;
    assign vif.status_if.issue_stall     = tb_issue_stall;
    assign vif.status_if.execute_stall   = tb_execute_stall;
    // core[0] scheduler active-warp bitmask for cp_active_warps (per-cycle sampled,
    // driven from core.schedule.active_warps in each ifdef branch; zero-extended).
    wire [31:0] tb_active_warps;
    assign vif.status_if.active_warps    = tb_active_warps;

    always @(posedge clk) begin
        if (reset_n && tb_cycle_count % 1000 == 0 && tb_cycle_count > 0 &&
            tb_execution_started && !tb_execution_complete)
            $display("[TB_STATUS @ %0t] cyc=%0d mem=%0d busy=%b idle=%0d",
                     $time, tb_cycle_count, tb_mem_ops, vif.status_if.busy, tb_idle_cycles);
    end

    //==========================================================================
    // DEBUG PROBES: Internal DUT busy and ebreak path
    //==========================================================================

    `ifdef USE_AXI_WRAPPER
        wire [`NUM_CLUSTERS-1:0] tb_probe_per_cluster_busy;
        assign tb_probe_per_cluster_busy = dut.vortex.per_cluster_busy;

        always @(posedge clk) begin
            if (reset_n && tb_cycle_count % 1000 == 0 && tb_cycle_count > 0 && tb_execution_started && !tb_execution_complete) begin
                $display("[TB_PROBE_AXI @ %0t] cyc=%0d per_cluster_busy=%b dut_busy=%b ebreak_detect=%b axi_idle=%b mem_idle=%b",
                         $time, tb_cycle_count, tb_probe_per_cluster_busy, vif.status_if.busy, vif.status_if.ebreak_detected,
                         axi_channels_idle, mem_channels_idle);
            end
        end
    `else
        wire [`NUM_CLUSTERS-1:0] tb_probe_per_cluster_busy;
        assign tb_probe_per_cluster_busy = dut.per_cluster_busy;

        always @(posedge clk) begin
            if (reset_n && tb_cycle_count % 1000 == 0 && tb_cycle_count > 0 && tb_execution_started && !tb_execution_complete) begin
                $display("[TB_PROBE_MEM @ %0t] cyc=%0d per_cluster_busy=%b dut_busy=%b ebreak_detect=%b mem_idle=%b",
                         $time, tb_cycle_count, tb_probe_per_cluster_busy, vif.status_if.busy, vif.status_if.ebreak_detected,
                         mem_channels_idle);
            end
        end
    `endif

    //==========================================================================
    // DEBUG PROBES: Deep RTL Pipeline Stage Analysis
    //==========================================================================

    `ifdef USE_AXI_WRAPPER
        // Deep pipeline probes: Measure fetch, decode, issue, LSU stages
        wire icache_req_valid, icache_rsp_valid, icache_req_ready, icache_rsp_ready;
        wire dcache_req_valid, dcache_rsp_valid, dcache_req_ready, dcache_rsp_ready;
        wire fetch_valid;
        wire [`XLEN-1:0] fetch_pc_full;
        wire [31:0] fetch_instr;

        localparam [31:0] TB_EBREAK_INSTR   = 32'h00100073;
        localparam [31:0] TB_EXIT_MMIO_ADDR = 32'h00000088;
        // tb_probe_ebreak_seen declared at module level (C3)

        // I1: generate loops — commit fires + ebreak detection across ALL cores/lanes.
        // cache/fetch wires for display keep core[0] reference (debug display only).
        genvar _cl, _sk, _co, _lw;
        generate
            for (_cl = 0; _cl < TB_NUM_CLUSTERS; _cl++) begin : g_axi_cl
                for (_sk = 0; _sk < TB_NUM_SOCKETS; _sk++) begin : g_axi_sk
                    for (_co = 0; _co < TB_SOCK_SIZE; _co++) begin : g_axi_co
                        localparam _CORE_IDX = _cl * TB_NUM_SOCKETS * TB_SOCK_SIZE
                                             + _sk * TB_SOCK_SIZE + _co;
                        localparam _LANE_BASE = _CORE_IDX * TB_ISSUE_W;
                        // ebreak: per core (fetch is before issue/lane split)
                        assign tb_ebreak_fetch_all[_CORE_IDX] =
                            dut.vortex.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.fetch_if.valid &&
                            (dut.vortex.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.fetch_if.data.instr == TB_EBREAK_INSTR);
                        for (_lw = 0; _lw < TB_ISSUE_W; _lw++) begin : g_axi_lw
                            assign tb_commit_fires_all[_LANE_BASE + _lw] =
                                dut.vortex.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.commit.commit_arb_if[_lw].valid &&
                                dut.vortex.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.commit.commit_arb_if[_lw].ready;
                        end
                    end
                end
            end
        endgenerate

        reg tb_probe_exit_addr_seen;

        // Cache/fetch display signals — core[0] only (debug telemetry, not pass/fail)
        assign icache_req_valid = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.req_valid;
        assign icache_req_ready = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.req_ready;
        assign icache_rsp_valid = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.rsp_valid;
        assign icache_rsp_ready = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.rsp_ready;

        assign fetch_valid   = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.valid;
        assign fetch_pc_full = VX_gpu_pkg::to_fullPC(dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.data.PC);
        assign tb_status_pc  = fetch_pc_full[31:0];  // drive status_if.pc for cp_pc_region
        assign fetch_instr   = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.data.instr;

        // DCACHE is an array; measure the first port (0)
        assign dcache_req_valid = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].req_valid;
        assign dcache_req_ready = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].req_ready;
        assign dcache_rsp_valid = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].rsp_valid;
        assign dcache_rsp_ready = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].rsp_ready;

        // Pipeline backpressure stalls (core[0]): valid && !ready at each stage boundary.
        //   decode_stall : decode not ready for fetch  (fetch_if.valid & !ready)
        //   issue_stall  : issue  not ready for decode (decode_if.valid & !ready)
        //   execute_stall: any EX unit not ready for dispatch (|dispatch_if[*].valid & !ready)
        localparam int TB_NDISP_A = VX_gpu_pkg::NUM_EX_UNITS * TB_ISSUE_W;
        wire [TB_NDISP_A-1:0] tb_disp_bp_a;
        for (genvar d = 0; d < TB_NDISP_A; d++) begin : g_disp_bp_a
            assign tb_disp_bp_a[d] =
                 dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dispatch_if[d].valid &&
                !dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dispatch_if[d].ready;
        end
        assign tb_decode_stall  = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.valid &&
                                 !dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.ready;
        assign tb_issue_stall   = dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.decode_if.valid &&
                                 !dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.decode_if.ready;
        assign tb_execute_stall = |tb_disp_bp_a;
        assign tb_active_warps  = 32'(dut.vortex.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.schedule.active_warps);

        // Pipeline flow signals
        reg [31:0] icache_stall_cycles, dcache_stall_cycles;
        wire icache_stalled = icache_req_valid && !icache_req_ready;
        wire dcache_stalled = dcache_req_valid && !dcache_req_ready;
        assign tb_fetch_stall  = icache_stalled;   // drive status_if.fetch_stall  (cp_fetch_stall)
        assign tb_memory_stall = dcache_stalled;   // drive status_if.memory_stall (cp_memory_stall)
        wire icache_firing = icache_req_valid && icache_req_ready;
        wire dcache_firing = dcache_req_valid && dcache_req_ready;

        always @(posedge clk) begin
            if (!reset_n) begin
                icache_stall_cycles <= 0;
                dcache_stall_cycles <= 0;
                tb_probe_ebreak_seen <= 0;
                tb_probe_exit_addr_seen <= 0;
            end else if (tb_execution_started && !tb_execution_complete) begin
                if (icache_stalled) icache_stall_cycles <= icache_stall_cycles + 1;
                if (dcache_stalled) dcache_stall_cycles <= dcache_stall_cycles + 1;

                if (!tb_probe_ebreak_seen && tb_ebreak_fetch) begin
                    tb_probe_ebreak_seen <= 1'b1;
                    $display("[TB_PROBE_EBREAK @ %0t] ebreak fetched at PC=0x%08h instr=0x%08h (core[0] PC shown; any core triggered)", $time, fetch_pc_full[31:0], fetch_instr);
                end

                if (!tb_probe_exit_addr_seen && vif.axi_if.awvalid && vif.axi_if.awready && (vif.axi_if.awaddr == TB_EXIT_MMIO_ADDR)) begin
                    tb_probe_exit_addr_seen <= 1'b1;
                    $display("[TB_PROBE_EXIT @ %0t] observed AXI write address 0x%08h (program exit MMIO)", $time, vif.axi_if.awaddr);
                end
            end
        end

        always @(posedge clk) begin
            if (reset_n && tb_cycle_count % 1000 == 0 && tb_cycle_count > 0 && tb_execution_started && !tb_execution_complete) begin
                $display("[TB_PROBE_PIPELINE @ %0t] cyc=%0d | ICACHE: req=%b ready=%b rsp=%b stall_cyc=%0d | DCACHE: req=%b ready=%b rsp=%b stall_cyc=%0d | PC=0x%08h instr=0x%08h ebreak_seen=%b exit_addr_seen=%b",
                         $time, tb_cycle_count,
                         icache_req_valid, icache_req_ready, icache_rsp_valid, icache_stall_cycles,
                         dcache_req_valid, dcache_req_ready, dcache_rsp_valid, dcache_stall_cycles,
                         fetch_pc_full[31:0], fetch_instr, tb_probe_ebreak_seen, tb_probe_exit_addr_seen);
            end
        end

    `else
        // MEM interface version (non-AXI)
        wire icache_req_valid, icache_rsp_valid, icache_req_ready, icache_rsp_ready;
        wire dcache_req_valid, dcache_rsp_valid, dcache_req_ready, dcache_rsp_ready;
        wire fetch_valid;
        wire [`XLEN-1:0] fetch_pc_full;
        wire [31:0] fetch_instr;

        localparam [31:0] TB_EBREAK_INSTR   = 32'h00100073;
        localparam [31:0] TB_EXIT_MMIO_ADDR = 32'h00000088;
        // tb_probe_ebreak_seen declared at module level (C3)

        // I1: generate loops — commit fires + ebreak detection across ALL cores/lanes.
        genvar _cl, _sk, _co, _lw;
        generate
            for (_cl = 0; _cl < TB_NUM_CLUSTERS; _cl++) begin : g_mem_cl
                for (_sk = 0; _sk < TB_NUM_SOCKETS; _sk++) begin : g_mem_sk
                    for (_co = 0; _co < TB_SOCK_SIZE; _co++) begin : g_mem_co
                        localparam _CORE_IDX = _cl * TB_NUM_SOCKETS * TB_SOCK_SIZE
                                             + _sk * TB_SOCK_SIZE + _co;
                        localparam _LANE_BASE = _CORE_IDX * TB_ISSUE_W;
                        assign tb_ebreak_fetch_all[_CORE_IDX] =
                            dut.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.fetch_if.valid &&
                            (dut.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.fetch_if.data.instr == TB_EBREAK_INSTR);
                        for (_lw = 0; _lw < TB_ISSUE_W; _lw++) begin : g_mem_lw
                            assign tb_commit_fires_all[_LANE_BASE + _lw] =
                                dut.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.commit.commit_arb_if[_lw].valid &&
                                dut.g_clusters[_cl].cluster.g_sockets[_sk].socket.g_cores[_co].core.commit.commit_arb_if[_lw].ready;
                        end
                    end
                end
            end
        endgenerate

        reg tb_probe_exit_addr_seen;

        // Cache/fetch display signals — core[0] only (debug telemetry, not pass/fail)
        assign icache_req_valid = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.req_valid;
        assign icache_req_ready = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.req_ready;
        assign icache_rsp_valid = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.rsp_valid;
        assign icache_rsp_ready = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.icache_bus_if.rsp_ready;

        assign fetch_valid   = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.valid;
        assign fetch_pc_full = VX_gpu_pkg::to_fullPC(dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.data.PC);
        assign tb_status_pc  = fetch_pc_full[31:0];  // drive status_if.pc for cp_pc_region
        assign fetch_instr   = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.data.instr;

        assign dcache_req_valid = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].req_valid;
        assign dcache_req_ready = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].req_ready;
        assign dcache_rsp_valid = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].rsp_valid;
        assign dcache_rsp_ready = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dcache_bus_if[0].rsp_ready;

        // Pipeline backpressure stalls (core[0]) — see AXI branch for semantics.
        localparam int TB_NDISP_M = VX_gpu_pkg::NUM_EX_UNITS * TB_ISSUE_W;
        wire [TB_NDISP_M-1:0] tb_disp_bp_m;
        for (genvar d = 0; d < TB_NDISP_M; d++) begin : g_disp_bp_m
            assign tb_disp_bp_m[d] =
                 dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dispatch_if[d].valid &&
                !dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.dispatch_if[d].ready;
        end
        assign tb_decode_stall  = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.valid &&
                                 !dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.fetch_if.ready;
        assign tb_issue_stall   = dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.decode_if.valid &&
                                 !dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.decode_if.ready;
        assign tb_execute_stall = |tb_disp_bp_m;
        assign tb_active_warps  = 32'(dut.g_clusters[0].cluster.g_sockets[0].socket.g_cores[0].core.schedule.active_warps);

        reg [31:0] icache_stall_cycles, dcache_stall_cycles;
        wire icache_stalled = icache_req_valid && !icache_req_ready;
        wire dcache_stalled = dcache_req_valid && !dcache_req_ready;
        assign tb_fetch_stall  = icache_stalled;   // drive status_if.fetch_stall  (cp_fetch_stall)
        assign tb_memory_stall = dcache_stalled;   // drive status_if.memory_stall (cp_memory_stall)

        always @(posedge clk) begin
            if (!reset_n) begin
                icache_stall_cycles <= 0;
                dcache_stall_cycles <= 0;
                tb_probe_ebreak_seen <= 0;
                tb_probe_exit_addr_seen <= 0;
            end else if (tb_execution_started && !tb_execution_complete) begin
                if (icache_stalled) icache_stall_cycles <= icache_stall_cycles + 1;
                if (dcache_stalled) dcache_stall_cycles <= dcache_stall_cycles + 1;

                if (!tb_probe_ebreak_seen && tb_ebreak_fetch) begin
                    tb_probe_ebreak_seen <= 1'b1;
                    $display("[TB_PROBE_EBREAK @ %0t] ebreak fetched at PC=0x%08h instr=0x%08h (core[0] PC shown; any core triggered)", $time, fetch_pc_full[31:0], fetch_instr);
                end

                if (!tb_probe_exit_addr_seen && vif.mem_if.req_valid[0] && vif.mem_if.req_ready[0] && vif.mem_if.req_rw[0] && (vif.mem_if.req_addr[0] == TB_EXIT_MMIO_ADDR[31:2])) begin
                    tb_probe_exit_addr_seen <= 1'b1;
                    $display("[TB_PROBE_EXIT @ %0t] observed MEM write address 0x%08h (program exit MMIO)", $time, TB_EXIT_MMIO_ADDR);
                end
            end
        end

        always @(posedge clk) begin
            if (reset_n && tb_cycle_count % 1000 == 0 && tb_cycle_count > 0 && tb_execution_started && !tb_execution_complete) begin
                $display("[TB_PROBE_PIPELINE @ %0t] cyc=%0d | ICACHE: req=%b ready=%b rsp=%b stall_cyc=%0d | DCACHE: req=%b ready=%b rsp=%b stall_cyc=%0d | PC=0x%08h instr=0x%08h ebreak_seen=%b exit_addr_seen=%b",
                         $time, tb_cycle_count,
                         icache_req_valid, icache_req_ready, icache_rsp_valid, icache_stall_cycles,
                         dcache_req_valid, dcache_req_ready, dcache_rsp_valid, dcache_stall_cycles,
                         fetch_pc_full[31:0], fetch_instr, tb_probe_ebreak_seen, tb_probe_exit_addr_seen);
            end
        end
    `endif

