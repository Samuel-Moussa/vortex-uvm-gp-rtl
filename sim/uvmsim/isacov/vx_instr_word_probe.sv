// Copyright (c) 2026 -- Vortex UVM GP.  Apache-2.0.
//==============================================================================
// vx_instr_word_probe.sv -- passive fetch-stage instruction-word observer.
//------------------------------------------------------------------------------
// Bound into EVERY VX_fetch instance:
//     bind VX_fetch vx_instr_word_probe u_instr_word_probe (.*);
// so it auto-scales over clusters x sockets x cores with no path enumeration,
// exactly like vx_commit_probe / vx_cache_probe.
//
// WHY THIS EXISTS
//   commit_t (VX_gpu_pkg.sv:651-663) carries no instruction word -- it is
//   dropped after decode.  The raw word survives only at
//   VX_fetch.sv:131:  assign fetch_if.data.instr = icache_bus_if.rsp_data.data;
//   This probe reads that assignment's source at the fetch handshake and hands
//   {PC, word} to isacov_pkg, which cross-checks it against the objdump map
//   that drives riscvISACOV.  It answers one question and only one:
//   "is the disassembly we are scoring coverage from the binary that ran?"
//
// STRICTLY PASSIVE
//   No modport (read-only by discipline), never drives fetch_if, never gates a
//   verdict.  Gated on +ISACOV, so a default run is byte-identical: with the
//   plusarg absent the always block does nothing at all.
//==============================================================================
module vx_instr_word_probe import VX_gpu_pkg::*; (
    input wire clk,
    input wire reset,
    VX_fetch_if fetch_if
);
    // The map is loaded EXACTLY ONCE, by whichever bound instance runs first.
    // There is no standalone loader module because there is nothing to
    // instantiate it from -- the binds are the only entry point this flist has.
    string map_path;
    initial begin
        if ($test$plusargs("ISACOV")) begin
            isacov_pkg::isacov_en = 1'b1;
            if (!isacov_pkg::map_loaded) begin
                if (!$value$plusargs("ISACOV_MAP=%s", map_path))
                    map_path = "isacov_map.txt";
                void'(isacov_pkg::load_map(map_path));
            end
        end
    end

    // One end-of-run report, from the first instance only.
    final if (isacov_pkg::isacov_en && !isacov_pkg::report_done) begin
        isacov_pkg::report_done = 1'b1;
        isacov_pkg::report();
    end

    // Elaboration sanity: the field must be a real 32-bit instruction word.
    initial assert ($bits(fetch_if.data.instr) == 32)
        else $fatal(1, "[ISACOV-PROBE] fetch instr width=%0d, expected 32",
                    $bits(fetch_if.data.instr));

    wire fetch_fire = fetch_if.valid && fetch_if.ready;

    longint unsigned n_fetch = 0;   // liveness: proves the bind elaborated

    always @(posedge clk) begin
        if (isacov_pkg::isacov_en && !reset && fetch_fire) begin
            n_fetch++;
            isacov_pkg::note_fetch(to_fullPC(fetch_if.data.PC), fetch_if.data.instr);
        end
    end

endmodule : vx_instr_word_probe
