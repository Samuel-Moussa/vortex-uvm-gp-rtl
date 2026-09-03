// coalesce_probe — directed memory-coalescing stimulus for gap G-0.
//
// WHY THIS EXISTS.
// VX_mem_coalescer (hw/rtl/libs/VX_mem_coalescer.sv) merges per-lane LSU
// requests into wider dcache-line transactions and had zero functional
// coverage. This kernel drives the coalescer through its three structurally
// distinct outcomes (see vx_coalescer_probe.sv for the exact per-request
// derivation), for BOTH loads and stores, so cp_coalesce_kind x cp_rw fills.
//
// GEOMETRY AT THE PRIMARY CONFIG (1CL/1C/4W/4T, XLEN=32).
// NUM_LSU_LANES = SIMD_WIDTH = NUM_THREADS = 4 (one warp = one coalescer
// "group"); DCACHE_WORD_SIZE = 16 bytes/line, LSU_WORD_SIZE = 4 bytes/word,
// so DATA_RATIO = 4 words/line. Three lane->address maps per warp-group of 4
// threads (tid = 0..3):
//   FULL     addr = base + tid*4B   -- all 4 lanes inside ONE 16B line
//              -> 1 output batch (cp_coalesce_kind == full_coalesced)
//   PARTIAL  addr = base + tid*8B   -- tid{0,1} share line0, tid{2,3} share
//              line1 -> 2 output batches from 4 active lanes, neither 1 nor
//              equal to active-lane count -> cp_coalesce_kind == partial
//   SCATTER  addr = base + tid*16B  -- every lane starts its OWN line
//              -> 4 output batches == active lane count
//              -> cp_coalesce_kind == full_scatter
// NOTE on the briefing's literal "stride 4 words" for the partial pattern:
// at THIS config (DATA_RATIO=4 words/line) a 4-word/16-byte stride puts every
// lane on its own line -- that is the SCATTER case, not partial (verified by
// hand-tracing VX_mem_coalescer.sv's addr_matches/batch logic). This kernel
// uses a 2-word/8-byte stride for the partial pattern instead, which is the
// stride that actually produces "lanes span 2+ lines" at NUM_REQS=4/
// DATA_RATIO=4. The RTL geometry wins over the literal number in the brief.
//
// SCOREBOARD / OBS-026 SAFETY (same discipline as csr_probe):
//   * store phase and load phase are TWO separate vx_spawn_threads calls with
//     the IDENTICAL total/geometry, so task i lands on the same core in both
//     phases (vx_spawn.c:299 contiguous distribution) -- no barrier needed.
//   * every thread writes/reads ONLY its own (group,tid) slot in each buffer.
//   * self-check reads back ONLY this core's contiguous slice of status_buf.
//   * status_buf/*_buf are NOT zero-initialised as whole arrays (OBS-026: a
//     whole-array init races once every core is active) -- every element is
//     written by exactly the thread that owns it before any thread reads it.
//   * deterministic integer values only, no FP.
//   * printf-free (INV-1).

#include <vx_intrinsics.h>
#include <vx_spawn.h>

#define MAX_TOTAL  128      // safe upper bound across configs we run
#define MAX_GROUPS 128      // group = i / nt; worst case nt=1 -> groups==total

typedef struct { int dummy; } cp_args_t;

// One warp-group's worth of lanes (tid 0..3) laid out three different ways.
// Sized DATA_RATIO(=4)-generic-enough for the configs this bench actually
// runs (NUM_THREADS<=4 lanes/group here); MAX_GROUPS bounds the outer dim.
static volatile int full_buf[MAX_GROUPS][4];     // stride 1 word  (4B)  -> full coalesce
static volatile int partial_buf[MAX_GROUPS][8];  // stride 2 words (8B)  -> partial
static volatile int scatter_buf[MAX_GROUPS][16]; // stride 4 words (16B) -> full scatter

static volatile int status_buf[MAX_TOTAL];

static int g_nt = 4;   // threads per warp-group, captured before spawn

static inline int expected_val(int g, int tid) {
  return g * 1000 + tid * 7 + 3;   // deterministic, nonzero, per-(group,tid)
}

// ---- Phase 1: STORE into all three layouts (per-lane, own slot only) -----
void store_kernel(cp_args_t *__UNIFORM__ args) {
  (void)args;
  int i   = blockIdx.x;
  int tid = i % g_nt;
  int g   = i / g_nt;
  int v   = expected_val(g, tid);

  full_buf[g][tid]        = v;
  partial_buf[g][tid * 2] = v;
  scatter_buf[g][tid * 4] = v;
}

// ---- Phase 2: LOAD back from all three layouts, verify, record status ----
void load_kernel(cp_args_t *__UNIFORM__ args) {
  (void)args;
  int i   = blockIdx.x;
  int tid = i % g_nt;
  int g   = i / g_nt;
  int exp = expected_val(g, tid);

  int a = full_buf[g][tid];
  int b = partial_buf[g][tid * 2];
  int c = scatter_buf[g][tid * 4];

  status_buf[i] = (a == exp && b == exp && c == exp) ? 1 : 0;
}

int main() {
  int nt = vx_num_threads();
  if (nt < 1) nt = 1;
  if (nt > 4) nt = 4;   // one coalescer group == one warp's lane set (<=4 here)
  g_nt = nt;

  uint32_t total = (uint32_t)vx_num_cores() * vx_num_warps() * vx_num_threads();
  if (total > MAX_TOTAL) total = MAX_TOTAL;
  // keep total a multiple of g_nt so every group is fully populated
  total = (total / (uint32_t)g_nt) * (uint32_t)g_nt;
  if (total == 0) total = (uint32_t)g_nt;

  cp_args_t args; args.dummy = 0;

  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)store_kernel, &args);
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)load_kernel,  &args);

  // Check ONLY this core's contiguous slice (vx_spawn.c:299) -- no barrier.
  uint32_t nc = (uint32_t)vx_num_cores(), cid = (uint32_t)vx_core_id();
  uint32_t per = total / nc, lo = cid * per, hi = lo + per;
  int errors = 0;
  for (uint32_t i = lo; i < hi; i++)
    if (status_buf[i] != 1) errors++;

  return errors;
}
