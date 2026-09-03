// Copyright (c) 2026 -- Vortex UVM GP.  Apache-2.0.
//==============================================================================
// isacov_pkg.sv -- static PC-keyed disassembly map + fetched-word cross-check.
//------------------------------------------------------------------------------
// WHY A MAP AND NOT A DECODER
//   riscvISACOV does not decode the instruction word. It parses DISASSEMBLY
//   TEXT:  RISCV_coverage_base.svh:1381 does
//       $sscanf(disass, "%s %s %s", insbin, ins_str, ops); return ins_str;
//   so the mnemonic is the SECOND whitespace token, and
//   RISCV_instruction_base.svh:119 pulls register NUMBERS out of the same
//   string ("x5" -> 5).  Measured proof (Step 4): the identical retirement
//   scored 0.00% with disass="addi x5,x0,10" and 2.55%/21 bins with
//   disass="00a00293 addi x5,x0,10".
//
//   Vortex kernels are not self-modifying, so a STATIC PC->text map built from
//   objdump is exact and needs no DPI, no SimX call and no RTL change.
//
// WHY THE FETCH PROBE EXISTS ANYWAY
//   A map is only as good as the ELF it came from.  This project has already
//   been burned once by a stale ELF silently surviving a source change
//   (fft_par16, 2026-09-01: .kernel_config.stamp gated on CONFIGS only).  The
//   probe records the instruction word the DUT ACTUALLY FETCHED at each PC and
//   this package compares it against the map's word.  A single mismatch means
//   the map describes a different binary than the one that ran, which would
//   silently fabricate ISA coverage.  That check is the probe's whole job --
//   it is never a pass/fail gate on the DUT.
//==============================================================================
package isacov_pkg;

    // Enabled by +ISACOV only. Default runs never touch any of this.
    bit                  isacov_en    = 1'b0;
    bit                  map_loaded   = 1'b0;
    bit                  report_done  = 1'b0;

    string               disass_map [logic [31:0]];  // PC -> "<hex> <mnem> <ops>"
    logic [31:0]         word_map   [logic [31:0]];  // PC -> instruction word (objdump)
    logic [31:0]         fetched    [logic [31:0]];  // PC -> instruction word (DUT fetch)

    longint unsigned n_map_entries   = 0;
    longint unsigned n_lookup_hit    = 0;
    longint unsigned n_lookup_miss   = 0;
    longint unsigned n_word_checked  = 0;
    longint unsigned n_word_mismatch = 0;
    longint unsigned n_sampled       = 0;

    // Map line format, one instruction per line, produced by gen_disass_map.sh:
    //     <pc_hex> <insn_hex> <mnemonic> <operands>
    // Everything from the SECOND field onward is handed to riscvISACOV verbatim,
    // which is exactly the "<hex> <mnem> <ops>" shape its $sscanf expects.
    function automatic int load_map(input string path);
        int    fd, cnt;
        string line;
        logic [31:0] pc, word;
        fd = $fopen(path, "r");
        if (fd == 0) begin
            $display("[ISACOV] FATAL: cannot open disassembly map '%s'", path);
            return 0;
        end
        cnt = 0;
        while ($fgets(line, fd) > 0) begin
            int sp1, sp2, i;
            // strip trailing newline / CR
            while (line.len() > 0 &&
                   (line[line.len()-1] == "\n" || line[line.len()-1] == "\r"))
                line = line.substr(0, line.len()-2);
            if (line.len() < 10) continue;
            sp1 = -1;
            for (i = 0; i < line.len(); i++)
                if (line[i] == " ") begin sp1 = i; break; end
            if (sp1 <= 0) continue;
            if ($sscanf(line.substr(0, sp1-1), "%h", pc) != 1) continue;
            // rest = everything after the PC field: "<insn_hex> <mnem> <ops>"
            begin
                string rest = line.substr(sp1+1, line.len()-1);
                if ($sscanf(rest, "%h", word) != 1) continue;
                disass_map[pc] = rest;
                word_map[pc]   = word;
                cnt++;
            end
        end
        $fclose(fd);
        n_map_entries = cnt;
        map_loaded    = (cnt > 0);
        $display("[ISACOV] loaded %0d disassembly entries from %s", cnt, path);
        return cnt;
    endfunction

    // Called by the fetch probe on every accepted fetch beat.
    function automatic void note_fetch(input logic [31:0] pc, input logic [31:0] word);
        if (fetched.exists(pc)) return;          // first observation is enough
        fetched[pc] = word;
        if (word_map.exists(pc)) begin
            n_word_checked++;
            if (word_map[pc] !== word) begin
                n_word_mismatch++;
                if (n_word_mismatch <= 5)
                    $display("[ISACOV] WORD MISMATCH @PC=0x%08h map=0x%08h fetched=0x%08h",
                             pc, word_map[pc], word);
            end
        end
    endfunction

    function automatic string lookup(input logic [31:0] pc);
        if (disass_map.exists(pc)) begin
            n_lookup_hit++;
            return disass_map[pc];
        end
        n_lookup_miss++;
        return "";                               // matches no covergroup
    endfunction

    function automatic void report();
        $display("[ISACOV] ---- disassembly map report ----");
        $display("[ISACOV]   map entries      : %0d", n_map_entries);
        $display("[ISACOV]   retirements samp : %0d", n_sampled);
        $display("[ISACOV]   PC lookups hit   : %0d", n_lookup_hit);
        $display("[ISACOV]   PC lookups MISS  : %0d", n_lookup_miss);
        $display("[ISACOV]   fetch PCs seen   : %0d", fetched.size());
        $display("[ISACOV]   word cross-checks: %0d", n_word_checked);
        $display("[ISACOV]   word MISMATCHES  : %0d", n_word_mismatch);
        if (n_word_mismatch != 0)
            $display("[ISACOV]   *** MAP DOES NOT MATCH THE RUNNING BINARY -- coverage is INVALID ***");
    endfunction

endpackage : isacov_pkg
