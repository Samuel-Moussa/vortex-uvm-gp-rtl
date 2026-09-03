// Copyright (c) 2026 -- Vortex UVM GP.  Apache-2.0.
//==============================================================================
// The two riscvISACOV binds, in their own compilation unit so that NO existing
// testbench file changes.
//
// They live INSIDE a module rather than at file scope on purpose: a file-scope
// bind sits in a $unit that nothing instantiates, so Questa never elaborates it
// and the binds silently do nothing -- measured, not assumed (first ISACOV run
// passed cleanly and produced zero [ISACOV] output).  This module is passed to
// vsim as a SECOND top alongside vortex_tb_top, which is what makes the binds
// take effect.  It has no ports and no logic of its own.
//==============================================================================
module vortex_isacov_top;

    bind VX_fetch  vx_instr_word_probe u_instr_word_probe (
        .clk     (clk),
        .reset   (reset),
        .fetch_if(fetch_if)
    );

    bind VX_commit vortex_rvvi_shim u_rvvi_shim (
        .clk          (clk),
        .reset        (reset),
        .commit_arb_if(commit_arb_if)
    );

endmodule : vortex_isacov_top
