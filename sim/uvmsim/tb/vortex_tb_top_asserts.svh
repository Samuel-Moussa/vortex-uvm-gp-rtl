// Copyright (c) 2026 -- Vortex UVM GP.
// SPDX-License-Identifier: Apache-2.0
//
// C1 / I2 elaboration asserts: UVM params == RTL compile-time params.
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
    // C1 — ELABORATION ASSERT: UVM VX_MEM_TAG_WIDTH == RTL VX_MEM_TAG_WIDTH
    // Both are derived from VX_gpu_pkg::VX_MEM_TAG_WIDTH. The first check
    // catches any future regression where someone re-hardcodes the UVM param.
    // The $bits check is the structural proof: DUT port width == UVM param.
    //==========================================================================
    initial begin : u_c1_tag_width_assert
        assert (vortex_config_pkg::VX_MEM_TAG_WIDTH == VX_gpu_pkg::VX_MEM_TAG_WIDTH)
            else $fatal(1, "[C1-ASSERT] VX_MEM_TAG_WIDTH: UVM_pkg=%0d RTL_pkg=%0d -- check vortex_config.sv",
                        vortex_config_pkg::VX_MEM_TAG_WIDTH, VX_gpu_pkg::VX_MEM_TAG_WIDTH);
`ifdef USE_AXI_WRAPPER
        assert ($bits(axi_awid[0]) == vortex_config_pkg::VX_MEM_TAG_WIDTH)
            else $fatal(1, "[C1-ASSERT] DUT AXI awid width=%0d bits but UVM VX_MEM_TAG_WIDTH=%0d",
                        $bits(axi_awid[0]), vortex_config_pkg::VX_MEM_TAG_WIDTH);
`endif
    end

    //==========================================================================
    // I2 — ELABORATION ASSERTS: UVM plusarg topology == RTL compile-time params
    // These fire at time=0 before any UVM phase runs. If +NUM_CLUSTERS=2 but
    // the RTL was compiled with `NUM_CLUSTERS=1, the bench is meaningless.
    // Pattern: read the plusarg (default = RTL value so single-config runs
    // always pass); fatal if the override disagrees with the compiled DUT.
    //==========================================================================
    initial begin : u_i2_topology_asserts
        int unsigned chk_clusters, chk_cores, chk_warps, chk_threads;

        // Default to the RTL compile-time values so the assert is a no-op
        // when the plusarg is not supplied (single-config baseline run).
        chk_clusters = TB_NUM_CLUSTERS;
        chk_cores    = `NUM_CORES;
        chk_warps    = `NUM_WARPS;
        chk_threads  = `NUM_THREADS;

        // Issue 3: accept both the NUM_* form and the short aliases the config
        // object reads (vortex_config.sv apply_plusargs). Check NUM_* first; if
        // absent, fall back to the alias so an alias-form override is also caught.
        if (!$value$plusargs("NUM_CLUSTERS=%d", chk_clusters))
            void'($value$plusargs("CLUSTERS=%d", chk_clusters));
        if (!$value$plusargs("NUM_CORES=%d", chk_cores))
            void'($value$plusargs("CORES=%d", chk_cores));
        if (!$value$plusargs("NUM_WARPS=%d", chk_warps))
            void'($value$plusargs("WARPS=%d", chk_warps));
        if (!$value$plusargs("NUM_THREADS=%d", chk_threads))
            void'($value$plusargs("THREADS=%d", chk_threads));

        assert (chk_clusters == TB_NUM_CLUSTERS)
            else $fatal(1,
                "[I2-ASSERT] NUM_CLUSTERS: plusarg=%0d but RTL compiled with %0d -- recompile with correct `NUM_CLUSTERS",
                chk_clusters, TB_NUM_CLUSTERS);

        assert (chk_cores == `NUM_CORES)
            else $fatal(1,
                "[I2-ASSERT] NUM_CORES: plusarg=%0d but RTL compiled with %0d -- recompile with correct `NUM_CORES",
                chk_cores, `NUM_CORES);

        assert (chk_warps == `NUM_WARPS)
            else $fatal(1,
                "[I2-ASSERT] NUM_WARPS: plusarg=%0d but RTL compiled with %0d -- recompile with correct `NUM_WARPS",
                chk_warps, `NUM_WARPS);

        assert (chk_threads == `NUM_THREADS)
            else $fatal(1,
                "[I2-ASSERT] NUM_THREADS: plusarg=%0d but RTL compiled with %0d -- recompile with correct `NUM_THREADS",
                chk_threads, `NUM_THREADS);

        $display("[I2-ASSERT] Topology OK: %0dCL %0dC %0dW %0dT (RTL == UVM plusargs)",
                 TB_NUM_CLUSTERS, `NUM_CORES, `NUM_WARPS, `NUM_THREADS);

        // ── I2 (extended): the REST of the STRUCTURAL config ──────────────────
        // Everything below is fixed at ELABORATION in the RTL, so a runtime plusarg
        // can only make the TB *believe* something the DUT does not implement — it
        // can never change the hardware. Historically only the topology was gated
        // here, which left silent TB/RTL drift possible on XLEN, the memory
        // interface, and the optional cache levels (see OBS-019). Fail loud instead,
        // and say exactly how to rebuild.
        begin
            // Snapshot the RTL's elaborated structural config into plain variables
            // first (no preprocessor conditionals inside expressions), then check.
            bit rtl_xlen64, rtl_icache, rtl_dcache;
            `ifdef XLEN_64
                rtl_xlen64 = 1'b1;
            `else
                rtl_xlen64 = 1'b0;
            `endif
            `ifdef ICACHE_ENABLE
                rtl_icache = 1'b1;
            `else
                rtl_icache = 1'b0;
            `endif
            `ifdef DCACHE_ENABLE
                rtl_dcache = 1'b1;
            `else
                rtl_dcache = 1'b0;
            `endif
            if (($test$plusargs("XLEN_64") || $test$plusargs("xlen=64")) && !rtl_xlen64)
                $fatal(1, "[I2-ASSERT] +XLEN_64 requested but the RTL was compiled XLEN_32 -- XLEN is compile-time: rebuild the RTL/SimX for 64-bit.");

            // Optional cache levels — PASSTHRU (no cache array) unless enabled at
            // compile time; VX_cache_wrap.sv:160 only instantiates VX_cache when
            // PASSTHRU==0. Terminal control is `make sim ... L2=1 L3=1`.
            if (($test$plusargs("L2CACHE") || $test$plusargs("l2cache")) && (`L2_ENABLED == 0))
                $fatal(1, "[I2-ASSERT] +L2CACHE requested but the RTL was elaborated WITHOUT L2 (PASSTHRU/bypass) -- rebuild with `make sim ... L2=1`.");
            if (($test$plusargs("L3CACHE") || $test$plusargs("l3cache")) && (`L3_ENABLED == 0))
                $fatal(1, "[I2-ASSERT] +L3CACHE requested but the RTL was elaborated WITHOUT L3 (PASSTHRU/bypass) -- rebuild with `make sim ... L3=1`.");

            // Memory interface — the AXI wrapper is a compile-time wrapper choice.
            `ifdef USE_AXI_WRAPPER
                if ($test$plusargs("MEM_INTERFACE"))
                    $fatal(1, "[I2-ASSERT] +MEM_INTERFACE requested but the RTL was compiled with USE_AXI_WRAPPER -- rebuild with `--interface=mem`.");
            `else
                if ($test$plusargs("USE_AXI_WRAPPER"))
                    $fatal(1, "[I2-ASSERT] +USE_AXI_WRAPPER requested but the RTL was compiled WITHOUT the AXI wrapper -- rebuild with `--interface=axi`.");
            `endif

            $display("[I2-ASSERT] Structural config OK: XLEN=%0d L2=%0d L3=%0d icache=%0d dcache=%0d (RTL == UVM)",
                     rtl_xlen64 ? 64 : 32, `L2_ENABLED, `L3_ENABLED, rtl_icache, rtl_dcache);
        end
    end

