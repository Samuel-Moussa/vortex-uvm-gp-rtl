#!/usr/bin/env python3
"""
gen_ext_coverage.py -- riscvISACOV extension coverage generator.

riscvISACOV (Imperas, Apache-2.0) publishes the DV plan for all 143 RISC-V
extensions as machine-readable CSV in dvplans/, but ships SystemVerilog source
for exactly ONE of them (RV32I).  The CSVs name every covergroup, every
coverpoint, its coverage TYPE, its operand and its description -- which is the
complete specification of the code that is withheld.

This generator turns those CSVs into the missing coverage source, using one
template per coverage TYPE.  Correctness is not asserted, it is PROVEN: running
the generator on RV32I's own dvplan must reproduce Imperas' RV32I_coverage.svh
exactly (see --verify).  A generator that reproduces the one published
extension byte-for-byte is a generator you can trust on the other 142.

  usage:
    gen_ext_coverage.py --ext RV32I --verify        # prove against Imperas' file
    gen_ext_coverage.py --ext RV32M --out <dir>     # emit the missing extension

Output is our own work under Apache-2.0; no Imperas source is copied into it.
"""
import argparse, csv, os, re, sys, difflib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "..", "third_party", "riscvISACOV"))

# ---------------------------------------------------------------------------
# Instruction long names.  These are the covergroup `option.comment` strings.
# They are NOT in the dvplan CSVs or the documentation -- they exist only in
# Imperas' source -- so they are supplied here from the RISC-V specification.
# Cosmetic: they affect no bin, no coverpoint and no coverage number.
# ---------------------------------------------------------------------------
LONG_NAMES = {}
FORMATS   = {}   # mnemonic -> ([operands], "load"|"store"|None)

# Coverpoint refinements that the dvplan CANNOT express. The CSV records that
# jalr has a cp_rs1_reg_assign; it has no field for "and x0 is excluded from its
# bins". Kept as an explicit, citable table rather than silently special-cased
# in a template -- one entry today, keyed (extension, covergroup, coverpoint).
CP_OVERRIDES = {
    # jalr's base register: rs1 == x0 is excluded. Imperas' RV32I_coverage.svh:1246.
    ("RV32I", "jalr_cg", "cp_rs1_reg_assign"): "        bins regs[] = gpr_regs_no_x0;\n",
}

def load_formats(path):
    with open(path) as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            k, _, v = line.partition("=")
            v, _, kind = (x.strip() for x in v.partition("|"))
            ops = [] if v.strip() == "none" else [o.strip() for o in v.split(",")]
            FORMATS[k.strip()] = (ops, kind or None)

def load_names(path):
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            k, _, v = line.partition("=")
            LONG_NAMES[k.strip()] = v.strip()

# ---------------------------------------------------------------------------
# Templates, one per coverage TYPE.  {op} is the operand (rd/rs1/rs2/imm),
# {mn} the mnemonic, {desc} the description string taken verbatim from the CSV.
# ---------------------------------------------------------------------------
IND = "    "

def t_asm_count(cp, op, desc, mn, extra=""):
    return (f'{IND}{cp} : coverpoint ins.ins_str == "{mn}"  iff (ins.trap == 0 )  {{\n'
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}    bins count[]  = {{1}};\n'
            f'{IND}}}\n')

def t_reg_assign(cp, op, desc, mn, extra=""):
    return (f'{IND}{cp} : coverpoint ins.get_gpr_reg(ins.current.{op})  iff (ins.trap == 0 )  {{\n'
            f'{IND}    option.comment = "{desc}";\n'
            f'{extra}'
            f'{IND}}}\n')

def t_reg_compare(cp, op, desc, mn, extra=""):
    # Two shapes share this TYPE, told apart by the cp_/cr_ prefix.
    m = re.match(r'c[pr]_(\w+?)_(\w+?)_compare$', cp)
    a, b = m.group(1), m.group(2)
    if cp.startswith("cp_"):
        return (f'{IND}{cp} : coverpoint ins.current.{a} == ins.current.{b}  iff (ins.trap == 0 )  {{\n'
                f'{IND}    option.comment = "{desc}";\n'
                f'{IND}}}\n')
    return (f'{IND}{cp} : cross cp_{a}_{b}_compare, cp_{a}_reg_assign iff (ins.trap == 0 )  {{\n'
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}    ignore_bins no_overlap = binsof(cp_{a}_{b}_compare) intersect {{0}};\n'
            f'{IND}}}\n')

def t_reg_value_sign(cp, op, desc, mn, extra=""):
    return (f"{IND}{cp} : coverpoint int32_t'(ins.current.{op}_val)  iff (ins.trap == 0 )  {{\n"
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}    bins neg  = {{[$:-1]}};\n'
            f'{IND}    bins pos  = {{[1:$]}};\n'
            f'{IND}    bins zero = {{0}};\n'
            f'{IND}}}\n')

VALUE_BINS = (f'{IND}    bins zeros = {{0}};\n'
              f"{IND}    bins min   = {{32'b10000000000000000000000000000000}};\n"
              f"{IND}    bins max   = {{32'b01111111111111111111111111111111}};\n"
              f"{IND}    bins ones  = {{32'b11111111111111111111111111111111}};\n"
              f"{IND}    bins one   = {{32'b00000000000000000000000000000001}};\n"
              f"{IND}    bins minp1 = {{32'b10000000000000000000000000000001}};\n")

def t_reg_value(cp, op, desc, mn, extra=""):
    # The description selects the variant: a compare-result destination gets a
    # two-bin true/false coverpoint, everything else the significant-values set.
    if desc.startswith("Check if compare was"):
        body = f'{IND}    bins zero = {{0}};\n{IND}    bins one  = {{1}};\n'
    else:
        body = VALUE_BINS
    return (f"{IND}{cp} : coverpoint uint32_t'(ins.current.{op}_val)  iff (ins.trap == 0 )  {{\n"
            f'{IND}    option.comment = "{desc}";\n'
            f'{body}'
            f'{IND}}}\n')

def t_reg_value_toggle(cp, op, desc, mn, extra=""):
    return (f"{IND}{cp} : coverpoint uint32_t'(ins.current.{op}_val)  iff (ins.trap == 0 )  {{\n"
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}    `RV32_BIT_TOGGLE_VALS\n'
            f'{IND}}}\n')

def t_reg_hazard(cp, op, desc, mn, extra=""):
    return (f'{IND}{cp} : coverpoint check_gpr_hazards(ins.hart, ins.issue)  iff (ins.trap == 0 )  {{\n'
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}}}\n')

def t_imm_value(cp, op, desc, mn, extra=""):
    return (f"{IND}{cp} : coverpoint int'(ins.current.imm)  iff (ins.trap == 0 )  {{\n"
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}    bins neg  = {{[$:-1]}};\n'
            f'{IND}    bins pos  = {{[1:$]}};\n'
            f'{IND}    bins zero = {{0}};\n'
            f'{IND}}}\n')

def t_mem_aligned(cp, op, desc, mn, extra=""):
    return (f'{IND}{cp} : coverpoint is_unaligned_mem_access(ins.hart, ins.issue)  {{\n'
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}}}\n')

def t_instr_divide(cp, op, desc, mn, extra=""):
    # NO REFERENCE IMPLEMENTATION EXISTS -- INSTR_DIVIDE appears in no published
    # riscvISACOV source, so unlike every other template this one is not
    # validated by the RV32I diff. It is written from the dvplan description
    # ("Check for divide-by-zero and over/underflow") and the RISC-V spec's two
    # special cases for DIV/REM: divisor == 0, and the signed overflow
    # -2^31 / -1. Flagged as OURS, not reconstructed.
    return (f'{IND}{cp} : coverpoint {{ins.current.rs2_val == 0,\n'
            f"{IND}                   int32_t'(ins.current.rs1_val) == 32'sh80000000\n"
            f"{IND}                   && int32_t'(ins.current.rs2_val) == -1}}"
            f'  iff (ins.trap == 0 )  {{\n'
            f'{IND}    option.comment = "{desc}";\n'
            f'{IND}    bins normal      = {{2\'b00}};\n'
            f'{IND}    bins overflow    = {{2\'b01}};\n'
            f'{IND}    bins div_by_zero = {{2\'b10}};\n'
            f'{IND}}}\n')

TEMPLATES = {
    "ASM_COUNT":        t_asm_count,
    "REG_ASSIGN":       t_reg_assign,
    "REG_COMPARE":      t_reg_compare,
    "REG_VALUE_SIGN":   t_reg_value_sign,
    "REG_VALUE":        t_reg_value,
    "REG_VALUE_TOGGLE": t_reg_value_toggle,
    "REG_HAZARD":       t_reg_hazard,
    "IMM_VALUE":        t_imm_value,
    "MEM_ALIGNED":      t_mem_aligned,
    "INSTR_DIVIDE":     t_instr_divide,
}

# INST_ILLEGAL is not a TEMPLATES entry: it is the `ifdef COVER_ILLEGAL_INST_*
# alternative branch that wraps the whole covergroup, emitted structurally.

# ---------------------------------------------------------------------------

def parse_dvplan(path):
    """CSV -> [(cg_name, mnemonic, [(cp_name, type, operand, desc), ...])]"""
    out, cur = [], None
    with open(path, newline="") as f:
        for row in csv.reader(f):
            row = (row + [""] * 6)[:6]
            ext, cg, cp, typ, operand, desc = (c.strip() for c in row)
            if ext and cg and typ == "instruction":
                cur = (cg, operand, [])          # operand column holds the mnemonic
                out.append(cur)
            elif cur is not None and cp and typ:
                cur[2].append((cp, typ, operand, desc))
    return out

def emit_covergroup(ext, cg, mn, cps):
    # ext/cg are needed for CP_OVERRIDES lookup
    low, up = ext.lower(), mn.upper()
    s  = f'covergroup {low}_{cg} with function sample(ins_{low}_t ins);\n'
    s += f'{IND}option.per_instance = 1; \n'
    s += f'{IND}option.comment = "{LONG_NAMES.get(mn, mn)}";\n'
    s += f'`ifdef COVER_ILLEGAL_INST_{up}\n'
    ill = next((c for c in cps if c[1] == "INST_ILLEGAL"), None)
    ill_desc = ill[3] if ill else "If instruction is not implemented in this configuration, check that exception is being hit"
    s += (f'{IND}cp_illegal_inst : coverpoint get_csr_val(ins.hart, ins.issue, '
          f'`SAMPLE_AFTER, "mcause", "") == `MCAUSE_ILLEGAL_INST  iff (ins.trap == 1 )  {{\n'
          f'{IND}    option.comment = "{ill_desc}";\n'
          f'{IND}}}\n')
    s += '`else\n'
    # Coverpoints are grouped into one `ifdef per TYPE, in CSV order.
    blocks, order = {}, []
    for cp, typ, op, desc in cps:
        if typ == "INST_ILLEGAL":
            continue
        if typ not in TEMPLATES:
            sys.exit(f"no template for coverage type '{typ}' (coverpoint {cp})")
        if typ not in blocks:
            blocks[typ] = []
            order.append(typ)
        ov = CP_OVERRIDES.get((ext, cg, cp))
        if ov is not None:
            blocks[typ].append(TEMPLATES[typ](cp, op, desc, mn, ov))
        else:
            blocks[typ].append(TEMPLATES[typ](cp, op, desc, mn))
    for typ in order:
        s += f'`ifdef COVER_TYPE_{typ}\n'
        s += "".join(blocks[typ])
        s += f'`endif  // COVER_TYPE_{typ}\n\n'
    s += f'`endif  // !COVER_ILLEGAL_INST_{up}\n'
    s += 'endgroup\n'
    return s

def emit_sample_fn(ext, plan):
    low = ext.lower()
    s  = f'function void {low}_sample(int hart, int issue);\n'
    s += f'{IND}ins_{low}_t ins;\n'
    s += f'{IND}// $display("inst=%s",traceDataQ[hart][issue][0].disass);\n\n'
    s += f'{IND}case (traceDataQ[hart][issue][0].inst_name)\n\n'
    for cg, mn, _ in sorted(plan, key=lambda p: p[0]):
        if mn not in FORMATS:
            sys.exit(f"no operand format for '{mn}' -- add it to inst_formats.txt")
        ops, kind = FORMATS[mn]
        s += f'        "{mn}"     : begin \n'
        s += f'            ins = new(hart, issue, traceDataQ); \n\n'
        for i, o in enumerate(ops):
            s += f'            ins.add_{o}({i});\n'
        if kind:
            s += f'            ins.current.inst_category = INST_CAT_{kind.upper()};\n'
            s += f'            ins.add_mem_address();\n'
        s += f'            {low}_{cg}.sample(ins); \n'
        s += f'        end\n\n'
    s = s[:-1]                      # no blank line before endcase
    s += f'{IND}endcase\n'
    s += 'endfunction\n\n'
    # CSR sampling hook. Empty for extensions that write no CSRs -- the base
    # class calls it unconditionally, so it must exist.
    s += f'function void {low}_sample_csrs(int compare, int index, int mask, int value, int hart, int issue);\n'
    s += 'endfunction\n\n\n'
    return s

HDR = """//
// Copyright (c) 2026 -- Vortex UVM GP.
//
// SPDX-License-Identifier: Apache-2.0
//
// GENERATED by isacov/gen/gen_ext_coverage.py from
//   third_party/riscvISACOV/dvplans/{ext}_coverage_dvplan.csv
// (Imperas, Apache-2.0). Do not edit by hand -- edit the generator.
//
// The generator is validated by regenerating RV32I from its own dvplan and
// diffing against Imperas' published RV32I_coverage.svh.
//
"""

def emit_file(ext, plan):
    low = ext.lower()
    s  = HDR.format(ext=ext)
    s += '\n \n\n\n'
    s += f'typedef RISCV_instruction #(ILEN, XLEN, FLEN, VLEN, NHART, RETIRE) ins_{low}_t;\n\n\n'
    # Covergroups are emitted in ALPHABETICAL covergroup-name order, which is
    # the order Imperas' own file uses; the _init.svh keeps the dvplan's order.
    for cg, mn, cps in sorted(plan, key=lambda p: p[0]):
        s += emit_covergroup(ext, cg, mn, cps) + '\n'
    s += '\n' + emit_sample_fn(ext, plan)
    return s

def emit_init(ext, plan):
    low = ext.lower()
    s  = HDR.format(ext=ext) + '\n \n'
    for cg, mn, _ in plan:
        s += f'{IND}{low}_{cg} = new(); {low}_{cg}.set_inst_name("{ext}::{cg}");\n'
    return s

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ext", required=True)
    ap.add_argument("--out")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--names", default=os.path.join(HERE, "inst_names.txt"))
    ap.add_argument("--formats", default=os.path.join(HERE, "inst_formats.txt"))
    a = ap.parse_args()

    if os.path.exists(a.names):
        load_names(a.names)
    if os.path.exists(a.formats):
        load_formats(a.formats)

    csv_path = os.path.join(REPO, "dvplans", f"{a.ext}_coverage_dvplan.csv")
    if not os.path.exists(csv_path):
        sys.exit(f"no dvplan for {a.ext}: {csv_path}")
    plan = parse_dvplan(csv_path)
    body = emit_file(a.ext, plan)

    if a.verify:
        ref = os.path.join(REPO, "source", "coverage", f"{a.ext}_coverage.svh")
        if not os.path.exists(ref):
            sys.exit(f"no reference source for {a.ext} -- cannot verify")
        # Compare from the typedef onward: the licence header is theirs, ours
        # is ours, and it contains no coverage content.
        cut = lambda t, m: t[t.index(m):]
        g, r = cut(body, "typedef RISCV_instruction"), cut(open(ref).read(), "typedef RISCV_instruction")
        ok = (g == r)
        # The _init.svh is verified too: it is what constructs every covergroup,
        # so a generator that got the .svh right and the init wrong would still
        # produce a design that samples nothing.
        iref = os.path.join(REPO, "source", "coverage", f"{a.ext}_coverage_init.svh")
        iok = None
        if os.path.exists(iref):
            gi = cut(emit_init(a.ext, plan), f"    {a.ext.lower()}_")
            ri = cut(open(iref).read(), f"    {a.ext.lower()}_")
            iok = (gi.strip() == ri.strip())
        if ok and iok is not False:
            print(f"VERIFY {a.ext}: BYTE-IDENTICAL to Imperas source "
                  f"({len(plan)} covergroups, {sum(len(c) for _,_,c in plan)} coverpoint rows)"
                  + ("; _init.svh also identical" if iok else ""))
            return 0
        if not iok and ok:
            print(f"VERIFY {a.ext}: coverage.svh identical but _init.svh DIFFERS")
            sys.stdout.writelines(list(difflib.unified_diff(
                ri.splitlines(True), gi.splitlines(True), "imperas_init", "generated_init"))[:40])
            return 1
        d = list(difflib.unified_diff(r.splitlines(True), g.splitlines(True),
                                      "imperas", "generated"))
        print(f"VERIFY {a.ext}: DIFFERS -- {len(d)} diff lines")
        sys.stdout.writelines(d[:200])
        return 1

    if not a.out:
        sys.exit("--out required when not verifying")
    os.makedirs(a.out, exist_ok=True)
    for name, txt in ((f"{a.ext}_coverage.svh", body),
                      (f"{a.ext}_coverage_init.svh", emit_init(a.ext, plan))):
        with open(os.path.join(a.out, name), "w") as f:
            f.write(txt)
        print(f"wrote {os.path.join(a.out, name)}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
