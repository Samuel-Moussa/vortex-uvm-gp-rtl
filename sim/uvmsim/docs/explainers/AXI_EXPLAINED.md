# AXI in this project — protocol, RTL, widths, and the UVM agent

*Read from live source: `Vortex/hw/rtl/Vortex_axi.sv`, `hw/rtl/libs/VX_axi_adapter.sv`,
`sim/uvmsim/tb/vortex_axi_if.sv`, `sim/uvmsim/uvm_env/agents/axi_agent/*`.*

---

# PART 1 — AXI as a protocol (the 60-second version)

**AMBA AXI4** is a burst-based, point-to-point **master/slave** interface. Its defining property
is that it is **five independent channels**, each with its own `VALID`/`READY` handshake:

| Channel | Direction | Carries |
|---|---|---|
| **AW** — write address | master → slave | address, ID, len, size, burst, prot… |
| **W** — write data | master → slave | data, `wstrb` byte enables, `wlast` |
| **B** — write response | slave → master | ID, `bresp` |
| **AR** — read address | master → slave | address, ID, len, size, burst… |
| **R** — read data | slave → master | data, ID, `rresp`, `rlast` |

**Four rules that matter for verification:**

1. **Handshake.** A transfer occurs on a rising clock edge where `VALID && READY`. Once `VALID`
   is asserted it **must not be deasserted** until the handshake completes, and the payload must
   stay stable. *→ this is what your `*_valid_stable` / `*_addr_stable` assertions check.*
2. **Channels are independent.** W data may legally arrive **before** its AW address. *→ your
   `cover_w_before_aw` cover property records whether that actually happens.*
3. **Transactions are tagged.** `AWID`/`ARID` allow multiple outstanding transactions, and
   responses may return **out of order** — the ID is how a master reassociates them. *→ this is
   what makes the ID width matter so much (Part 3).*
4. **Bursts.** `LEN` = beats−1, `SIZE` = log2(bytes per beat), `BURST` ∈ {FIXED, INCR, WRAP}.
   A burst may not cross a 4 KB boundary. *→ your `aw_4k_boundary` / `ar_4k_boundary` and
   `*_burst_legal` / `*_size_legal` / `*_wrap_len_legal` assertions.*

**AXI4 vs AXI4-Lite:** Lite drops bursts, IDs and most attributes. Vortex uses **full AXI4** —
`Vortex_axi.sv` exposes `awlen`, `awsize`, `awburst`, `awlock`, `awcache`, `awprot`, `awqos`,
`awregion` and the ID signals.

---

# PART 2 — How AXI is used in the Vortex RTL

## 2.1 Where it sits

Vortex's native internal memory interface is **`VX_mem_bus_if`**, not AXI. AXI appears only at the
device boundary:

```
Vortex core/cluster/L2/L3 hierarchy
        │  VX_mem_bus_if  (native: req_valid/req_ready/rsp_valid/tag/byteen/…)
        ▼
VX_axi_adapter.sv      ← protocol conversion
        │  AXI4 master
        ▼
Vortex_axi.sv          ← top-level wrapper, exposes m_axi_* ports
        │
        ▼
external memory  (in simulation: the UVM AXI agent + memory model)
```

`Vortex_axi.sv` is parameterized:

```systemverilog
module Vortex_axi import VX_gpu_pkg::*; #(
    parameter AXI_DATA_WIDTH = VX_MEM_DATA_WIDTH,
    parameter AXI_ADDR_WIDTH = `MEM_ADDR_WIDTH,
    parameter AXI_TID_WIDTH  = VX_MEM_TAG_WIDTH,
    parameter AXI_NUM_BANKS  = 1
)
```

Every port is an **array** `[AXI_NUM_BANKS]` — the design supports multiple parallel AXI ports.

## 2.2 ⭐ The critical fact: Vortex is a *restricted* AXI master

`VX_axi_adapter.sv` does **not** generate the full AXI feature space. It hardwires most of it:

```systemverilog
// write address channel — VX_axi_adapter.sv:262-267
assign m_axi_awlen[i]   = 8'b00000000;        // 1 beat  → single-beat only
assign m_axi_awsize[i]  = 3'(LOG2_DATA_SIZE); // full native width only
assign m_axi_awburst[i] = 2'b00;              // FIXED burst type
assign m_axi_awlock[i]  = 2'b00;              // no exclusive access
assign m_axi_awcache[i] = 4'b0000;            // no cache attributes
assign m_axi_awprot[i]  = 3'b000;             // no protection attributes

// read address channel — :297-299
assign m_axi_arlen[i]   = 8'b00000000;
assign m_axi_arsize[i]  = 3'(LOG2_DATA_SIZE);
assign m_axi_arburst[i] = 2'b00;

// responses — :313, :332
assign m_axi_bready[i]  = 1'b1;                    // ⚠ fire-and-forget writes
assign m_axi_rready[i]  = rsp_xbar_ready_in[i];    //   real backpressure on reads
```

**Why this matters more than it looks — it is the RTL evidence behind a whole class of coverage
exclusions.** Because the master can only ever emit `len=0`, `burst=FIXED`, `size=native`:

| Coverpoint | Reachable space | Disposition |
|---|---|---|
| `cp_len` | one value | structurally waived, cited |
| `cp_burst` | FIXED only | structurally waived, cited |
| `cp_size` | native only (was 12.5% → 100%) | structurally waived, cited |
| `cross_type_burst_size` | one combination | waived (12.5% → 100%) |
| `b_valid_stable` assertion | **unreachable** | waived — `bready` tied high means the slave can never be made to stall a B beat |

**`bready = 1'b1` is finding R9** — the fire-and-forget write path. Two consequences you should
state as a pair:
1. **Verification:** one class of response-stability assertion is structurally untestable. Cited
   as an exclusion at `VX_axi_adapter.sv:313`, not silently dropped.
2. **Design:** the master **cannot observe a write error response**. `bresp` = `SLVERR`/`DECERR`
   would be accepted and discarded. That is in the upstream recommendation list — consuming write
   responses would both close the error hole and make the untestable assertions meaningful.

**Note the asymmetry:** `rready` is *not* tied high — it comes from `rsp_xbar_ready_in`, so the
read path **can** backpressure. That is why `+AXI_FLOOD` exists (streaming R beats to force DUT
`rready` low) and why `r_valid_stable`/`r_data_stable` are reachable-but-unhit — reported red,
not waived.

---

# PART 3 — The widths actually used

| Parameter | Value | Where it comes from |
|---|---|---|
| `AXI_DATA_WIDTH` | **512 bits** | `VX_MEM_DATA_WIDTH = L3_LINE_SIZE * 8`; `L3_LINE_SIZE = MEM_BLOCK_SIZE = 64` bytes |
| `AXI_STRB_WIDTH` | **64** | `DATA_WIDTH/8` — one byte-enable per byte |
| `AXI_ADDR_WIDTH` | **32** (RV32) / 48 (RV64) | `` `MEM_ADDR_WIDTH `` — a **byte** address |
| `AXI_ID_WIDTH` | **50** (debug build) | `VX_MEM_TAG_WIDTH` — *derived*, see below |
| `AXI_NUM_BANKS` | 1 (primary config) | port count |
| Burst length | 1 beat | `awlen`/`arlen` = 0 |

**One beat is a full 64-byte cache line.** A "transaction" here is a line fill or line write —
which is why a burst is unnecessary and `len = 0` is not a limitation in practice.

## 3.1 ⭐ The ID width — your Gate-0 checklist item C1

`AXI_ID_WIDTH` is **not 8**, despite comments in the original code claiming so. It is
`VX_gpu_pkg::VX_MEM_TAG_WIDTH` = **50** in the debug build (7 with `NDEBUG`), because the tag
carries routing and uuid information composed through the cache hierarchy:

```systemverilog
// tb/vortex_axi_if.sv:40
parameter ID_WIDTH = vortex_config_pkg::AXI_ID_WIDTH; // = VX_gpu_pkg::VX_MEM_TAG_WIDTH (derived)
```

```systemverilog
// uvm_env/vortex_config.sv:79
parameter AXI_ID_WIDTH = VX_MEM_TAG_WIDTH;   // = VX_gpu_pkg::VX_MEM_TAG_WIDTH (NOT 8)
```

**Why this was a real bug, not a cosmetic one:** the value was originally hardcoded `50` with
comments saying `8`. Hardcoding it means a config change silently produces an interface width
mismatch — `vsim-8451` at elaboration, or worse, silent truncation of routing bits. The fix was
to **derive it from the RTL package and add an elaboration assert** that the UVM parameter equals
the DUT parameter. That is what makes the interface config-generic instead of pinned.

**Do not build with `NDEBUG`** — it collapses `UUID_WIDTH` to 1, which destroys the uuid key that
lockstep, the probes and the DPI layer all depend on.

---

# PART 4 — The AXI agent, and the UVM↔DUT relationship

## 4.1 ⭐ The role inversion

> **The DUT is the AXI *master*. The UVM agent is the *slave*.**

This is the opposite of a typical UVM AXI VIP, where the testbench masters transactions into a
DUT slave. Vortex fetches its own instructions and data, so it *issues* AW/W/AR and the testbench
must *answer* on B/R.

```
┌──────────────────┐                          ┌────────────────────────────┐
│  Vortex DUT      │  AW / W  ──────────────► │  UVM AXI agent (responder) │
│  (AXI MASTER)    │  AR      ──────────────► │                            │
│                  │  ◄──────────────  B / R  │   axi_driver ── mem_model  │
└──────────────────┘                          │   axi_monitor ─► analysis  │
                                              └────────────────────────────┘
```

## 4.2 The driver has no sequencer connection at all

```systemverilog
virtual task run_phase(uvm_phase phase);
    wait(vif.reset_n === 1'b1);
    fork
        handle_aw_channel();
        handle_w_channel();
        handle_b_channel();
        handle_ar_r_channels();
    join_none
endtask
```

**Four concurrent `forever` loops, one per channel group — and no `seq_item_port.get_next_item()`
anywhere in the file.** The driver is not sequence-driven; it is reactive. This models AXI's
channel independence directly: each channel runs its own handshake loop, exactly as the protocol
specifies.

Consequence: the `axi_*_seq` classes in `axi_sequences.svh` are **bring-up scaffolding for a
master-mode agent and are never started**. Be ready to say that plainly.

The driver hard-fails without memory, because a responder with nothing behind it would answer
zeros and every comparison would silently pass:

```systemverilog
`uvm_fatal("AXI_DRV", "Failed to get mem_model from config DB! AXI responder requires memory access.")
```

## 4.3 How a write is serviced — byte-accurate

```systemverilog
// AW: capture address + ID into queues
if (vif.awvalid && vif.awready) begin
    aw_queue.push_back(vif.awid);
    aw_addr_queue.push_back(vif.awaddr);
end

// W: apply 64 byte-enables into the memory model
if (vif.wvalid && vif.wready && aw_active) begin
    automatic bit [511:0] data  = vif.wdata;
    automatic bit  [63:0] wstrb = vif.wstrb;
    for (int i = 0; i < 64; i++)
        if (wstrb[i]) memory.write_byte(addr + i, data[i*8 +: 8]);

    if (vif.wlast) begin
        b_resp_q.push_back(aw_active_id);   // B carries the FULL-WIDTH AW ID back
        aw_active = 1'b0;
    end
end
```

**Two details worth pointing at in an interview:**

- **`wstrb` is honoured per byte**, so sub-word stores land exactly. This is what lets the
  end-state scoreboard do byte-exact comparison and what makes the per-byte validity mask in the
  scoreboard meaningful.
- **The AW context is latched and held until `WLAST`**, and the ID is carried through to the B
  response at full width. Truncating the ID here would break response association — and with a
  50-bit ID, truncation is a live hazard, not a theoretical one.

## 4.4 The stress modes live in the responder

Because there is no stimulus sequence path, protocol-corner stimulus is injected from the **slave
side**, plusarg-gated, default OFF, and **proven byte-identical when off**:

```systemverilog
// +AXI_THROTTLE — pulse awready high 1-in-4 so an arriving awvalid
// reliably sees !awready for >=1 cycle → exercises the stability assertions
vif.awready <= throttle_en ? ((thr_aw % 4) == 0) : 1'b1;

// wready pulses 1-in-5 while a write is active
vif.wready  <= aw_active && (throttle_en ? ((thr_w % 5) == 0) : 1'b1);
```

- **`+AXI_THROTTLE`** — ready wait-states. This is what created the `!READY` windows the
  `*_valid_stable` / `*_addr_stable` / `*_data_stable` assertions need. Moved AXI assertion
  coverage **84.78% → 93%**.
- **`+AXI_FLOOD`** — the slave streams R responses back-to-back to force DUT-side `rready`
  backpressure.

**This is the clean answer to "how do you stress a protocol when you can't drive it":** you cannot
change what the master emits, but you *can* change when you accept it — and the timing of your
`READY` is a first-class stimulus axis.

## 4.5 The monitor and the checkers

- **`axi_monitor`** is passive: it reconstructs transactions and publishes them on an analysis
  port for coverage. It renders no verdicts.
- **Protocol correctness** is checked by the **40 concurrent assertions bound in the interface**
  (30 of them on AXI), *not* by the monitor — assertions see every cycle, a monitor only sees
  completed transactions.
- **Data correctness** is checked by the end-state scoreboard against SimX. The AXI path's job is
  to make the memory model an accurate mirror of what the DUT actually wrote.

---

# PART 5 — One-paragraph answer for the interview

> "Vortex exposes a full AXI4 master at the device boundary through `Vortex_axi.sv`, converted
> from its native `VX_mem_bus_if` by `VX_axi_adapter.sv`. The data path is 512 bits — one 64-byte
> cache line per beat — with a 64-bit `wstrb`, a 32-bit byte address on RV32, and a 50-bit ID
> derived from the RTL's `VX_MEM_TAG_WIDTH` rather than hardcoded, with an elaboration assert
> that the testbench parameter matches the DUT's. It is a deliberately restricted master:
> `len=0`, `burst=FIXED`, `size=native`, and `bready` tied high. That restriction is why several
> AXI coverpoints are structurally unreachable, and every one of those exclusions is cited to the
> adapter line that causes it. Because the DUT is the master, the UVM AXI agent is a *responder* —
> four concurrent channel loops backed by a memory model, with no sequencer connection at all.
> Protocol stress therefore comes from the slave side as plusarg-gated `READY` throttling and read
> flooding, which is what exercises the handshake-stability assertions; both are proven
> byte-identical when disabled."

---

# Numbers to have ready

| | |
|---|---|
| Protocol | AXI4 full (not Lite) — 5 channels, ID-tagged |
| Data width | **512 bits** (64-byte line) |
| Strobe width | **64** |
| Address width | **32** (RV32) / 48 (RV64), byte-addressed |
| ID width | **50** — derived from `VX_MEM_TAG_WIDTH`, not hardcoded |
| Burst | `len=0` (single beat), `burst=FIXED`, `size=native` |
| `bready` | tied `1'b1` → fire-and-forget writes (**finding R9**) |
| `rready` | real backpressure from the response crossbar |
| AXI assertions | **30** (of 40 total in the environment) |
| AXI cover properties | **16** → Directive coverage 100% |
| Agent role | **Responder / slave** — DUT is master |
| Driver structure | 4 forked `forever` loops, **no `get_next_item`** |
| Stress modes | `+AXI_THROTTLE` (ready 1-in-4 / 1-in-5), `+AXI_FLOOD` |
| Assertion coverage | 96.9% (1CL) / 98.9% (2CL) |
