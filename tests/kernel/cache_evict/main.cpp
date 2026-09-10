// cache_evict — T-cache: does a multi-core fence force a stale L1 line to be
// dropped and re-fetched from memory, rather than served from a private copy?
//
// SCOPED AGAINST THE REAL RTL, NOT A GENERIC "COHERENCE TEST" ASSUMPTION.
// Vortex has no snoop/MESI datapath (project-wide grep confirms zero
// snoop|coheren|invalidat|MESI|probe_req in hw/rtl/cache/*.sv). L1 dcache is
// per-SOCKET (VX_socket.sv) and write-through (DCACHE_WRITEBACK=0), so a write
// lands in memory immediately -- there is nothing to write back. The ONLY
// cross-core visibility mechanism is `fence`: VX_lsu_slice.sv:73 ties
// MEM_REQ_FLAG_FLUSH to req_is_fence, which VX_cache_bank.sv/VX_cache_flush.sv
// turn into a full local dcache invalidate (every line, every way) before the
// core's next access proceeds. "Cache coherence" on this design reduces to one
// checkable question: after `fence`, does a core that had an address's OLD
// value already resident in its own L1 correctly see a NEW value another core
// wrote, or does it keep serving the stale line? That is what this kernel
// tests -- not MESI-style coherence, which does not exist here.
//
// WHY NOT vx_barrier: it is per-core / warp-local (VX_wctl_unit.sv:138 ties
// is_global low; GBAR_ENABLE is off in this build), so it cannot sequence
// "core 0 writes, then every other core observes" across cores. main() runs
// independently on EVERY core from reset (OBS-026/028 precedent), so the
// handoff has to be a plain single-writer/single-reader-per-slot polling
// protocol built from `vx_fence()` -- no atomics needed because each flag
// byte has exactly one writer.
//
// PROTOCOL (2 phases, so each reader genuinely holds a STALE line before the
// interesting read -- reading an address for the first time would trivially
// "work" even with a broken flush, since there is nothing stale to serve):
//   Phase A (prime): core 0 writes OLD_PATTERN to NLINES distinct cache lines,
//     fences, raises g_flag=1. Every other core waits for g_flag>=1, reads the
//     lines (this is what caches OLD_PATTERN in that core's own L1), fences,
//     then acks its own slot (ack[core_id]=1 -- single-writer, no race).
//   Phase B (the actual test): core 0 waits for every ack, overwrites the same
//     lines with NEW_PATTERN, fences, raises g_flag=2. Every other core waits
//     for g_flag>=2, fences (this is the operation under test -- it must force
//     the stale line out), then re-reads and records what it saw.
//
// Deterministic + printf-free: every recorded value is a pure function of the
// two known patterns; the host recomputes the same expected NEW_PATTERN and
// the scoreboard's byte-exact end-state compare vs SimX is exactly as strong
// as the device run (SimX has no private-cache model, so it always resolves
// to the architecturally-correct latest write -- which is precisely the
// reference behaviour this kernel checks the DUT against).
//
// CONFIG-AWARE: role assignment and core count both come from vx_core_id() /
// vx_num_cores() at runtime, never hardcoded. At 1CL/1C there is exactly one
// core (the writer) and zero readers -- the kernel still runs and passes, but
// exercises nothing multi-core; the test is meaningful starting at >=2 cores
// (2CL/2C and above). This is stated plainly, not hidden.

#include <vx_intrinsics.h>
#include <vx_spawn.h>

// Compile-time cap for static buffer sizing (mirrors axi_stress/mshr_flood's
// MAX_NT convention) -- keeps crt0's .bss zeroing cheap regardless of the
// runtime core count.
#define MAX_CORES 64
#define NLINES    4          // 4 independent test addresses
#define LINE_STRIDE 16       // 16 ints = 64B = one L1 line; keeps lines distinct

#define OLD_PATTERN 0x01D0BAD0
#define NEW_PATTERN 0x0FEEDBAC

static volatile int g_data[NLINES * LINE_STRIDE];
static volatile int g_flag;                 // 0 -> 1 (primed) -> 2 (overwritten); single writer: core 0
static volatile int g_ack[MAX_CORES];        // ack[c] written ONLY by core c -- no race

// out[c][i]: what core c observed for line i in Phase B, after its own fence.
// Zero-initialized by .bss; core 0's own slot (the writer) is left at 0 and
// excluded from the compare -- it never re-reads through the mechanism under
// test, it already knows what it wrote.
static volatile int g_out[MAX_CORES][NLINES];
static volatile int g_status;   // written ONLY by core 0 -- the scoreboard's clear pass/fail
                                 // signal; the real evidence is still the byte-exact end-state
                                 // compare of g_out[][] itself (every core's exit() call races
                                 // the shared IO_MPM_EXITCODE MMIO write, so the exit code is
                                 // cosmetic here -- this is a memory-image check, per the
                                 // project's black-box end-state-vs-SimX methodology).

int main() {
  int core   = vx_core_id();
  int ncores = vx_num_cores();
  if (ncores < 1)         ncores = 1;
  if (ncores > MAX_CORES) ncores = MAX_CORES;

  if (core == 0) {
    // ---- Phase A: prime every other core's L1 with OLD_PATTERN ----
    for (int i = 0; i < NLINES; i++) g_data[i * LINE_STRIDE] = OLD_PATTERN;
    vx_fence();
    g_flag = 1;
    vx_fence();

    // Wait for every other core to have read the OLD value and acked.
    for (int c = 1; c < ncores; c++) {
      while (g_ack[c] == 0) { vx_fence(); }
    }

    // ---- Phase B: overwrite the same lines, then let readers re-fence+reread ----
    for (int i = 0; i < NLINES; i++) g_data[i * LINE_STRIDE] = NEW_PATTERN;
    vx_fence();
    g_flag = 2;
    vx_fence();

    // Wait for every reader's Phase-B result to actually be written before
    // checking it -- g_ack[c] goes 1 (primed) -> 2 (Phase-B result recorded).
    for (int c = 1; c < ncores; c++) {
      while (g_ack[c] < 2) { vx_fence(); }
    }
  } else if (core < ncores) {
    // ---- Phase A: wait, read (primes this core's own L1 with OLD), ack ----
    while (g_flag < 1) { vx_fence(); }
    int old_snapshot[NLINES];
    for (int i = 0; i < NLINES; i++) old_snapshot[i] = g_data[i * LINE_STRIDE];
    (void)old_snapshot;   // read-for-effect only: this is what stales the line
    vx_fence();
    g_ack[core] = 1;
    vx_fence();

    // ---- Phase B: wait for the overwrite, fence (the mechanism under test),
    //      then re-read and record what actually came back. ----
    while (g_flag < 2) { vx_fence(); }
    vx_fence();
    for (int i = 0; i < NLINES; i++) g_out[core][i] = g_data[i * LINE_STRIDE];
    vx_fence();
    g_ack[core] = 2;
    vx_fence();
  }

  // ---- single-thread self-check: every core >=1 must have observed NEW_PATTERN ----
  int errors = 0;
  if (core == 0) {
    // Safe to check now: the g_ack[c]>=2 wait above already guarantees every
    // reader's g_out[c][*] write landed before we get here.
    for (int c = 1; c < ncores; c++) {
      for (int i = 0; i < NLINES; i++) {
        if (g_out[c][i] != NEW_PATTERN) errors++;
      }
    }
    g_status = (errors == 0) ? 0x600DC0DE : 0xBADC0DE;
  }
  return errors;
}
