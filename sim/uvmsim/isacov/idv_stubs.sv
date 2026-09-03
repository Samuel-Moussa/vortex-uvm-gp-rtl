// ============================================================================
// idv_stubs.sv — minimal stand-ins for the two ImperasDV packages that
// riscvISACOV imports but the public Apache-2.0 sample does not ship.
//
// WHY THIS EXISTS
//   third_party/riscvISACOV/source/coverage/RISCV_coverage_pkg.svh:25-28 does:
//       import idvPkg::*;
//       import rvviApiPkg::*;     <- real, ships with third_party/RVVI
//       import idvApiPkg::*;
//   `idvPkg` and `idvApiPkg` belong to ImperasDV, a commercial product we do
//   not have. A SystemVerilog `import` requires the package to exist at compile
//   time even when no imported symbol is referenced, so the coverage package
//   cannot elaborate without them.
//
//   Measured, not assumed: across the ENTIRE riscvISACOV source tree only TWO
//   idv-prefixed symbols are ever referenced (verified by grep over
//   source/**/*.svh). Both are stubbed faithfully below. Nothing else from
//   ImperasDV is used, so no functionality is lost for RV32I coverage.
//
// LICENCE NOTE
//   This file is OURS. It contains no Imperas code. riscvISACOV itself stays
//   unmodified under third_party/ with its Apache-2.0 headers intact, so the
//   licence obligation is satisfied by leaving that tree alone.
// ============================================================================

package idvPkg;

    // Used ONLY by third_party/riscvISACOV/source/coverage/RISCV_config_checks.svh,
    // at 7 call sites, every one of them inside an `ifdef branch that fires only
    // on a CONTRADICTORY base-ISA selection (e.g. COVER_BASE_RV32I together with
    // COVER_BASE_RV32E). With a single valid base ISA selected, the preprocessor
    // removes every one of those calls before elaboration -- so this function
    // exists to satisfy the import, and firing it means we mis-configured the
    // build. Fatal is therefore the correct behaviour, not a placeholder.
    function automatic void idvMsgFatal(input string msg);
        $fatal(1, "[idvPkg-stub] %s", msg);
    endfunction

endpackage : idvPkg


package idvApiPkg;

    // Used ONLY by RISCV_coverage_base.svh:1835,1961, both inside sample_csrs().
    // In ImperasDV this pops the next CSR-compare record from the reference
    // model's queue; the do/while loop in sample_csrs() runs until it returns "".
    //
    // We have no ImperasDV reference model, so returning "" immediately is the
    // CORRECT stub, not a degraded one: the loop performs zero iterations and
    // sample_csrs() becomes a no-op. That matches our scope -- CSR coverage is
    // out of scope for the RV32I bank, and Vortex's architectural CSR state is
    // already covered by end-state comparison plus the existing lockstep check.
    //
    // If CSR coverage is ever wanted, this is the exact seam to revisit: it
    // would need a real source of {hart, index, mask, value} records, which is
    // a new probe, not a change to this stub.
    function automatic string idvRefCoverPointNext(input string name);
        return "";
    endfunction

endpackage : idvApiPkg
