# RAL — the concept, the standard mechanics, and how this project uses it

*Part 2 read from live source: `uvm_env/ral/vortex_dcr_ral_pkg.sv` (388 lines),
`tb/vx_dcr_probe.sv`, and the bind at `tb/vortex_tb_top.sv:1006`.*

---

# PART 1 — RAL as a general concept

## 1.1 What it is

**RAL = Register Abstraction Layer**, the UVM facility (`uvm_reg_*` classes) that models a design's
**programmable registers** as objects, so tests manipulate them **by name** rather than by address
and bus protocol.

```systemverilog
// Without RAL — brittle, protocol-coupled, unreadable
bus_seq.write(32'h4000_0010, 32'h0000_0003);

// With RAL — intent is visible, protocol is abstracted
regs.ctrl.mode.set(3);
regs.ctrl.update(status);
```

## 1.2 The problems it solves

1. **Address/protocol coupling.** A test that hardcodes addresses breaks when the memory map moves,
   and must be rewritten entirely if the bus changes from APB to AXI. RAL puts the map in one place
   and the protocol behind an adapter.
2. **No independent model of expected register state.** Without RAL, "what *should* this register
   contain?" lives in the test author's head. RAL maintains a **mirror**.
3. **Field-level semantics are lost.** Registers are not 32 undifferentiated bits — they are fields
   with widths, reset values, and **access policies** (a `W1C` bit behaves nothing like an `RW`
   bit). RAL encodes that.
4. **Register tests are boilerplate.** Reset-value checks, bit-bashing, front/backdoor consistency
   — the same tests for every design. RAL ships them.

## 1.3 The class structure

```
uvm_reg_block          ← the whole register map (can nest sub-blocks)
 ├── uvm_reg_map       ← address map: which register at which offset, endianness, bus width
 ├── uvm_reg           ← one register
 │    └── uvm_reg_field ← one field: width, lsb position, access policy, reset value
 └── uvm_mem           ← memory regions (arrays, not individually mirrored)

uvm_reg_adapter        ← translates uvm_reg_bus_op ↔ your bus sequence_item
uvm_reg_predictor      ← updates the mirror from OBSERVED bus traffic (monitor side)
uvm_reg_backdoor       ← optional: direct HDL access, bypassing the bus
```

## 1.4 ⭐ The three values — the heart of RAL

Every field carries **three** distinct notions of its value. Confusing them is the most common
source of false failures:

| Value | Meaning | Accessed by |
|---|---|---|
| **Desired** | What you *want* it to become — staged, not yet written | `set()` / `get()` |
| **Mirrored** | What RAL *believes* the hardware currently holds | `get_mirrored_value()` / `predict()` |
| **Actual** | What the hardware *really* holds | only by reading/peeking the DUT |

Verification is the business of proving **mirrored == actual**.

## 1.5 The standard operations

| Method | Path | Effect |
|---|---|---|
| `write()` | frontdoor (bus) | Drive a bus write; update mirror |
| `read()` | frontdoor (bus) | Drive a bus read; update mirror; return value |
| `poke()` | **backdoor** (HDL) | Force the HDL storage directly — no bus activity |
| `peek()` | **backdoor** (HDL) | Sample the HDL storage directly |
| `set()` / `get()` | none | Stage / query the *desired* value only |
| `update()` | frontdoor | Write desired to HW **if** it differs from mirror |
| `mirror()` | either | Read HW into the mirror; with `UVM_CHECK`, **compare** |
| `predict()` | none | Force the mirror to a value (used by predictors) |

**Frontdoor vs backdoor** is the key distinction:
- **Frontdoor** exercises the real bus — it verifies decode, timing, protocol, and access policy.
  It costs simulation time.
- **Backdoor** reaches the storage element directly (via `add_hdl_path()` or a custom
  `uvm_reg_backdoor`). Zero simulation time, and it can reach registers the bus cannot.

**The classic use is to combine them:** write frontdoor, peek backdoor, compare. That proves the
bus path *and* the storage.

## 1.6 Access policies

RAL encodes read/write semantics per field so the mirror updates correctly:

`RW` · `RO` · `WO` · `RC` (read-clears) · `RS` (read-sets) · `WC` · `WS` ·
`W1C` (write-1-clears) · `W1S` · `W1T` (toggle) · `W0C` · `W0S` · `WRC` · `WRS` ·
`W1SRC` · `WOC` · `WO1` (write-once) · `NOACCESS`

This matters: after reading an `RC` field the mirror must become 0, and a model that assumed `RW`
would report a false mismatch on the next check.

## 1.7 Prediction — three models

**How does the mirror stay in step with hardware?**

| Model | Mechanism | Sees writes issued outside RAL? |
|---|---|---|
| **Auto-predict** | `map.set_auto_predict(1)` — the map updates the mirror on ops it issues | ❌ **No** |
| **Explicit** | `uvm_reg_predictor` subscribed to the **monitor's** analysis port | ✅ **Yes** |
| **Passive** | No RAL-issued ops at all; mirror driven purely by prediction | ✅ Yes |

> **Explicit prediction is the recommended model**, and the reason is exactly the trap this project
> hit: auto-predict updates the mirror **only for writes issued through the register model**. Any
> traffic from a legacy sequence, another master, or the DUT itself lands in hardware while the
> mirror stays stale — and the next check reports a mismatch that looks like a DUT bug.

## 1.8 The built-in test sequences

RAL ships standard register tests, which is a large part of its value:

| Sequence | Checks |
|---|---|
| `uvm_reg_hw_reset_seq` | Every register reads its specified **reset value** |
| `uvm_reg_bit_bash_seq` | Walks 1s and 0s through **every writable bit**, honouring access policy |
| `uvm_reg_access_seq` | **Frontdoor and backdoor agree** for every register |
| `uvm_reg_shared_access_seq` | Registers reachable from multiple maps behave consistently |
| `uvm_mem_walk_seq` / `uvm_mem_access_seq` | Memory equivalents |
| `uvm_reg_mem_hdl_path_seq` | The declared backdoor HDL paths actually resolve |
| `uvm_reg_mem_built_in_seq` | Runs the whole set |

Individual registers can opt out via `uvm_resource_db` attributes such as `NO_REG_TESTS`,
`NO_REG_BIT_BASH_TEST`, `NO_REG_HW_RESET_TEST`.

## 1.9 Where register models come from

In industry, hand-writing RAL is unusual. The model is normally **generated** from a machine-
readable spec — **IP-XACT**, **SystemRDL**, or a spreadsheet — by a generator, so the RTL, the
firmware headers, the documentation, and the RAL all derive from **one source**. That is what
prevents the four from drifting apart.

---

# PART 2 — RAL in this project

## 2.1 ⭐ The problem: the bus is write-only

`VX_dcr_bus_if` (`interfaces/VX_dcr_bus_if.sv:18-31`) carries `write_valid`, `write_addr`,
`write_data` — **and no read channel at all.**

That breaks the normal RAL value proposition outright:

- `read()` is **impossible** — there is nothing to read from.
- `mirror()` with `UVM_CHECK` cannot run.
- **None of the built-in sequences apply** — `hw_reset_seq`, `bit_bash_seq` and `access_seq` all
  require a read path.

So before this work, the question *"did this configuration write actually land in the RTL
register?"* was **unanswerable**. The DCR bus was write-and-hope.

## 2.2 The solution: a bind probe as the backdoor

Rather than `add_hdl_path()` (which needs a stable hierarchical path per instance), the read side
comes from a **`bind`-instantiated peek-only probe** into the register module itself:

```systemverilog
bind VX_dcr_data vx_dcr_probe u_dcr_probe (
    .clk(clk), .reset(reset),
    .write_valid(dcr_bus_if.write_valid),
    .write_addr (dcr_bus_if.write_addr),
    .write_data (dcr_bus_if.write_data),
    .dcrs       (dcrs)            // ← the module's INTERNAL storage register
);
```

**Two properties this buys:**

- **Config-aware by construction.** `VX_core.sv:82` instantiates `VX_dcr_data` once per core, so
  the bind creates exactly one probe per core the configuration actually built — **at any
  topology, with no path enumeration.** A conventional `add_hdl_path()` backdoor would need one
  path string per core.
- **⚠ Peek-only, by construction.** The probe never drives. This is not stylistic: the scoreboard
  feeds SimX off the DCR monitor, so a backdoor **`poke()`** would change the DCR waveform, desync
  the golden model, and produce a green run that verified nothing. **`poke()` is unavailable here
  on purpose.**

## 2.3 The register model

**A single parameterized register class** rather than five near-identical ones — the registers
differ only in width and offset:

```systemverilog
class vortex_dcr_reg extends uvm_reg;
    rand uvm_reg_field value;
    int unsigned m_width;

    function new(string name = "vortex_dcr_reg");
        super.new(name, 32, UVM_NO_COVERAGE);   // 32-bit container
    endfunction

    virtual function void build_with(int unsigned width);
        m_width = width;
        value = uvm_reg_field::type_id::create("value");
        // Write-only in hardware. Reads are served by the backdoor checker,
        // never by a bus read, so the access policy is honestly "WO".
        value.configure(this, width, 0, "WO", 0, 0, 1, 1, 0);
    endfunction
endclass
```

Note the discipline: the access policy is **`WO`** because that is what the hardware is — not `RW`
for convenience.

**Registers that do not exist in this build are not created at all:**

```systemverilog
rand vortex_dcr_reg startup_addr0, startup_arg0, mpm_class;
`ifdef XLEN_64
    rand vortex_dcr_reg startup_addr1, startup_arg1;
`endif
```

`STARTUP_ADDR1`/`ARG1` are `` `ifdef XLEN_64 `` in the RTL (`VX_dcr_data.sv:35-41`), so on RV32 a
write to them falls to `default:;` and is silently dropped. **Modelling them anyway would mean
checking storage that was never built** — the same config-aware-by-construction principle as the
cache probe.

**The map** — with an easily-missed detail:

```systemverilog
dcr_map = create_map("dcr_map", 0, 4, UVM_LITTLE_ENDIAN, 0);
// Offsets are the RAW DCR word addresses (VX_types.vh:23-27) — NOT byte-shifted.
startup_addr0 = mk("startup_addr0", 32, VX_DCR_BASE_STARTUP_ADDR0);
startup_arg0  = mk("startup_arg0",  32, VX_DCR_BASE_STARTUP_ARG0);
mpm_class     = mk("mpm_class",      8, VX_DCR_BASE_MPM_CLASS);   // ← 8 bits, not 32
```

## 2.4 The adapter — honest about what the bus cannot do

```systemverilog
virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    dcr_transaction tr = dcr_transaction::type_id::create("tr");
    if (rw.kind != UVM_WRITE)
        `uvm_fatal("DCR_RAL",
            "DCR bus is write-only (VX_dcr_bus_if has no read channel) — a frontdoor read is impossible. Use the backdoor checker instead.")
    tr.addr = rw.addr[VX_DCR_ADDR_WIDTH-1:0];
    tr.data = rw.data[VX_DCR_DATA_WIDTH-1:0];
    return tr;
endfunction
```

A frontdoor read is a **`uvm_fatal` naming the reason and the alternative** — not a silent return
of garbage. The adapter reuses the **existing** DCR agent, so RAL sits on top of the environment
rather than replacing it.

## 2.5 ⭐ Explicit prediction — and why auto-predict was wrong here

```systemverilog
dcr_map.set_auto_predict(0);
lock_model();
```

The in-tree comment states the measurement:

> Auto-predict only updates the mirror for writes issued **through** the reg model, but most DCR
> traffic in this bench comes from legacy sequences driving the agent directly (the bootstrap
> vseq, `host_coverage_vseq`). With auto-predict those writes land in the RTL while the mirror
> stays at its initial value, so the backdoor check reports a mismatch on every one of them — a
> testbench artefact that looks exactly like a DUT bug (**measured: 11 false errors** on
> `host_coverage_test`).

Predicting off the **monitor** means every observed write updates the mirror regardless of who
issued it — so **the check covers legacy stimulus too**, which is strictly more valuable than
RAL-only coverage. Textbook §1.7, arrived at from evidence.

## 2.6 ⭐ The checker — comparing against the right thing

The subtlest part. The naive implementation compares each observation against
`get_mirrored_value()`. That is **wrong whenever an address is written more than once**:

```systemverilog
// NOT rg.get_mirrored_value(): the mirror holds the LAST value written, while
// observations are historical. Comparing every observation against the final
// mirror produces a false mismatch for each earlier write — measured as 10 false
// errors on host_coverage_test, which sweeps DCR values.
expected = (w >= 64) ? o.wdata : (o.wdata & ((64'h1 << w) - 64'h1));
actual   = o.value;
```

Each observation is compared against **the write that produced it**, truncated to the field width.

**And that truncation is where the register model earns its place:**

> The register model supplies that width, which is the modelling value it adds: `MPM_CLASS` is
> 8 bits in RTL (`VX_dcr_data.sv:42` captures `write_data[7:0]`), so a 32-bit compare would report
> a testbench bug as a DUT failure.

Without RAL you would need that width knowledge somewhere anyway — RAL is where it belongs.

**Other details:**

- **Drained in `check_phase`** — every DCR write has retired by then, and it keeps the checker off
  the run-phase critical path.
- **Unmapped addresses are counted, not failed** — an `XLEN_64`-only address on RV32 is dropped by
  the RTL too, so there is nothing to check. But liveness is recorded **before** the unmapped
  filter, because an observation still proves that probe instance exists and is reporting.
- **Non-vacuity hook** — `+DCR_RAL_INJECT` corrupts exactly one observation so the check is forced
  to fail, proving the comparison can report. Same discipline as `+INJECT_FAULT` / `+DROP_STORE`.

## 2.7 The result

**15/15 observations checked, 0 failed.** The RTL stored every DCR write correctly — including
`MPM_CLASS`'s 8-bit truncation. Non-vacuity proven by injection. No regression:
`vecadd_lite data_compared=84` unchanged, both Gate-0 guards still red.

## 2.8 How this differs from textbook RAL — say this proactively

| Textbook RAL | Here |
|---|---|
| Frontdoor read + write | **Write only** — no read channel exists |
| Backdoor via `add_hdl_path()` | **`bind` probe** — config-generic, no path strings |
| `poke()` available | **Deliberately unavailable** — would desync the golden model |
| Built-in sequences are the main value | **None apply** — all need a read path |
| Value = protocol + policy checking | **Value = creating observability that did not exist**, plus field-width modelling and config-conditional existence |

**This is an atypical RAL deployment, and that is the interesting part.** The standard value
proposition was unavailable, so RAL was used for what remained: an address→register map, authoritative
field widths, build-conditional register existence, and a predictor that tracks *all* bus traffic.

---

# One-paragraph answer for the interview

> "RAL is UVM's register abstraction layer — `uvm_reg_block`/`uvm_reg`/`uvm_reg_field` model the
> register map as objects, an adapter translates generic register operations into your bus's
> sequence items, and a predictor keeps a mirror of what the hardware should hold. The core idea is
> the three values: desired, mirrored, and actual, and verification is proving mirrored equals
> actual — normally by writing frontdoor and reading back, plus the built-in sequences like
> `hw_reset_seq`, `bit_bash_seq` and `access_seq`. My case was unusual: the device configuration
> bus is write-only in the RTL, so there is no read channel, no `mirror()`, and none of the
> built-in sequences apply. I supplied the missing read side with a `bind`-instantiated peek-only
> probe into the register module's internal storage — config-generic, since the RTL instantiates
> that module once per core, so it scales without path enumeration. I used explicit prediction off
> the monitor rather than auto-predict, because most DCR traffic comes from legacy sequences that
> bypass the register model, and I compare each observation against the write that produced it
> truncated to the modelled field width, rather than against the final mirror. That last point is
> where the register model earns its keep — one of those registers is 8 bits wide in hardware, so a
> 32-bit compare would report a testbench bug as a DUT failure."

---

# Quick reference

| | |
|---|---|
| Classes | `uvm_reg_block` · `uvm_reg` · `uvm_reg_field` · `uvm_reg_map` · `uvm_reg_adapter` · `uvm_reg_predictor` |
| Three values | **desired** (`set`) · **mirrored** (`get_mirrored_value`) · **actual** (in the DUT) |
| Frontdoor | Real bus — checks decode, timing, policy |
| Backdoor | Direct HDL — `peek`/`poke`, zero sim time |
| Prediction | auto-predict · **explicit (recommended)** · passive |
| Built-in seqs | `hw_reset` · `bit_bash` · `access` · `shared_access` · `mem_walk` · `built_in` |
| **Here: bus** | **Write-only** — frontdoor read is `uvm_fatal` |
| **Here: backdoor** | `bind` probe on `VX_dcr_data`, **peek-only** |
| **Here: prediction** | Explicit, off the monitor (auto-predict caused 11 false errors) |
| **Here: compare** | Per-observation, field-width-truncated (mirror compare caused 10 false errors) |
| Result | **15/15 checked, 0 failed**; non-vacuity via `+DCR_RAL_INJECT` |
| Model size | 388 lines, 3 registers on RV32 (5 on RV64) |
