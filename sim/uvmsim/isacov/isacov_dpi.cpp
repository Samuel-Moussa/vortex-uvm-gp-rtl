// Copyright (c) 2026 -- Vortex UVM GP.  Apache-2.0.
//=============================================================================
// isacov_dpi.cpp -- the one RVVI DPI function riscvISACOV actually calls.
//
// RVVI's rvviApiPkg.sv declares 66 `import "DPI-C"` functions, all of which are
// implemented by ImperasDV -- a commercial product (Imperas, now Synopsys). We
// have no ImperasDV, so every one of them is a null function pointer at run
// time. QuestaSim does not complain at elaboration; it aborts the moment one is
// called:
//     ** Fatal: (vsim-160) rvviApiPkg.sv(280): Null foreign function pointer
//        encountered when calling 'rvviRefCsrIndex'
//
// Exactly ONE of the 66 is on our path. RISCV_instruction_base.svh:490, inside
// add_csr(), does
//     current.imm2 = rvviRefCsrIndex(current.hart, ops[offset].key);
// so any extension with a CSR operand -- RV32Zicsr, i.e. every csrrw/csrrs/csrrc
// in the program, including the ones crt0 issues before main() -- hits it on its
// first instruction.
//
// This is a pure NAME-TO-NUMBER DECODER. It resolves a CSR spelling to its
// address. It is NOT a reference model, it makes no architectural decision, and
// it cannot influence a pass/fail verdict -- it only supplies the number the
// coverage model uses to label a CSR. Implementing it ourselves is therefore
// sound; implementing rvviRefCsr*VALUE* functions would not be, and we do not.
//
// Two spellings arrive, because that is what objdump emits with
// `-M numeric,no-aliases`: standard CSRs come out by name ("fcsr", "mcycle"),
// and everything else -- including all of Vortex's GPU CSRs -- comes out as a
// hex literal ("0xfc1"). Both are handled; anything unrecognised returns -1
// rather than a plausible-looking wrong number.
//=============================================================================
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <string>
#include <unordered_map>

extern "C" {

static const std::unordered_map<std::string, int>& csr_table() {
    static const std::unordered_map<std::string, int> t = {
        // User floating-point (the only writable ones this project touches)
        {"fflags", 0x001}, {"frm", 0x002}, {"fcsr", 0x003},
        // User counters
        {"cycle", 0xC00}, {"time", 0xC01}, {"instret", 0xC02},
        {"cycleh", 0xC80}, {"timeh", 0xC81}, {"instreth", 0xC82},
        // Machine information
        {"mvendorid", 0xF11}, {"marchid", 0xF12}, {"mimpid", 0xF13},
        {"mhartid", 0xF14},
        // Machine trap setup / handling
        {"mstatus", 0x300}, {"misa", 0x301}, {"medeleg", 0x302},
        {"mideleg", 0x303}, {"mie", 0x304}, {"mtvec", 0x305},
        {"mcounteren", 0x306}, {"mscratch", 0x340}, {"mepc", 0x341},
        {"mcause", 0x342}, {"mtval", 0x343}, {"mip", 0x344},
        // Machine counters
        {"mcycle", 0xB00}, {"minstret", 0xB02},
        {"mcycleh", 0xB80}, {"minstreth", 0xB82},
        // Physical memory protection
        {"pmpcfg0", 0x3A0}, {"pmpaddr0", 0x3B0},
        // Supervisor (decoded by objdump even though Vortex is M-mode only)
        {"satp", 0x180},
    };
    return t;
}

// Returns the CSR address, or -1 if the spelling is not recognised.
int rvviRefCsrIndex(int hartId, const char* csrName) {
    (void)hartId;                       // Vortex CSR numbering is not per-hart
    if (csrName == nullptr) return -1;

    // Hex literal form, e.g. "0xfc1" -- every Vortex GPU CSR arrives this way.
    if (csrName[0] == '0' && (csrName[1] == 'x' || csrName[1] == 'X')) {
        char* end = nullptr;
        long v = std::strtol(csrName + 2, &end, 16);
        if (end && *end == '\0' && v >= 0 && v < 4096) return (int)v;
        return -1;
    }
    // mhpmcounter3..31 and their high halves, which objdump spells out.
    if (std::strncmp(csrName, "mhpmcounter", 11) == 0) {
        const char* p = csrName + 11;
        char* end = nullptr;
        long n = std::strtol(p, &end, 10);
        if (n >= 3 && n <= 31) {
            if (end && *end == '\0')                 return (int)(0xB00 + n);
            if (end && end[0] == 'h' && end[1] == 0) return (int)(0xB80 + n);
        }
        return -1;
    }
    auto it = csr_table().find(csrName);
    return (it == csr_table().end()) ? -1 : it->second;
}

} // extern "C"
