// toggle_stress — high-entropy memory kernel to maximise TOGGLE code coverage.
//
// Our functional/directed tests optimise for correctness signals, not bit entropy,
// so wide datapaths (64-byte cache-line data buses = 512 bits, buffer/arbiter
// payloads, MSHR request/response data) sit at near-constant values and never
// toggle. Post-exclusion ~75% of the toggle gap is exactly these DATA bits.
//
// This kernel drives every data bit through both 0->1 and 1->0:
//   - Writes a 32KB buffer (2x the 16KB dcache -> forces WRITEBACKS, pushing
//     high-entropy line data onto the memory WRITE bus) then reads it back
//     (forces MISSES -> high-entropy FILLS on the memory READ bus).
//   - Uses 8 COMPLEMENTARY patterns (0x00<->0xFF, 0xAA<->0x55, 0xCC<->0x33,
//     0xF0<->0x0F): consecutive patterns flip every bit, and each word is further
//     XORed with its index so the full 512-bit line + address bits vary.
//   - Bursts across warps -> many outstanding requests -> varied MSHR/mem tags.
//
// Multi-core aware: total = NUM_CLUSTERS*NUM_CORES*NUM_WARPS*NUM_THREADS so every
// hardware core/warp participates (also lights up per-core coverage instances).
//
// Deterministic + printf-free: each buffer word is written by exactly one thread,
// final state = PAT[last]^idx, and out_buf[tid] is a pure XOR reduction -> the
// DUT-vs-SimX end-state compare is byte-exact (scoreboard-safe).

#include <stdint.h>
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>      // NUM_CLUSTERS, NUM_CORES, NUM_WARPS, NUM_THREADS, MEM_BLOCK_SIZE

#define LINE_WORDS  (MEM_BLOCK_SIZE / 4)                 // 16 words / 64B line
#define NLINES      512                                  // 512*64B = 32KB (> 16KB dcache)
#define BUFW        (NLINES * LINE_WORDS)                // 8192 words
#define NPAT        8
#define TOTAL       (NUM_CLUSTERS * NUM_CORES * NUM_WARPS * NUM_THREADS)

// Complementary high-entropy patterns: consecutive entries flip every bit.
static const uint32_t PAT[NPAT] = {
  0x00000000u, 0xFFFFFFFFu, 0xAAAAAAAAu, 0x55555555u,
  0xCCCCCCCCu, 0x33333333u, 0xF0F0F0F0u, 0x0F0F0F0Fu
};

typedef struct { uint32_t *buf; uint32_t *out; } tg_args_t;

volatile uint32_t g_buf[BUFW];
volatile uint32_t g_out[TOTAL];

static inline uint32_t reduce_thread(uint32_t *buf, int tid, int total) {
  uint32_t acc = 0;
  for (int p = 0; p < NPAT; p++) {
    // write phase: this thread's strided lines get pattern p (^ index for per-word entropy)
    for (int L = tid; L < NLINES; L += total) {
      int base = L * LINE_WORDS;
      for (int w = 0; w < LINE_WORDS; w++) buf[base + w] = PAT[p] ^ (uint32_t)(base + w);
    }
    // read-back phase: reload (forces misses after evictions) and XOR-reduce
    for (int L = tid; L < NLINES; L += total) {
      int base = L * LINE_WORDS;
      for (int w = 0; w < LINE_WORDS; w++) acc ^= buf[base + w];
    }
  }
  return acc;
}

void tg_kernel(tg_args_t *__UNIFORM__ args) {
  int tid = blockIdx.x;
  args->out[tid] = reduce_thread(args->buf, tid, TOTAL);
}

int main() {
  for (int i = 0; i < BUFW;  i++) g_buf[i] = 0;
  for (int i = 0; i < TOTAL; i++) g_out[i] = 0;
  tg_args_t args; args.buf = (uint32_t *)g_buf; args.out = (uint32_t *)g_out;
  uint32_t total = TOTAL;
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)tg_kernel, &args);
  return 0;   // scoreboard (DUT vs SimX: g_buf final state + g_out) is the authority
}
