// compute_dense — printf-free, memory-light, ALU-bound kernel to drive high IPC.
//
// Purpose: cp_ipc_bucket med_ipc/high_ipc bins (real IPC in 0.50..1.00). The
// functional suite is memory- and control-bound, so IPC stays in zero/very_low/
// low buckets. This kernel spawns all warps, each running a long chain of
// INDEPENDENT arithmetic ops with no memory access in the hot loop, so the four
// warps keep the single issue slot busy nearly every cycle -> IPC approaches the
// ISSUE_WIDTH=1 ceiling (~1.0) -> high_ipc bin (and med_ipc during ramp/drain).
// One load + one store per thread only, at the ends. printf-free (INV-1).
// Result to memory for the DUT-vs-SimX scoreboard.

#include <vx_intrinsics.h>
#include <vx_spawn.h>

#define N 16

typedef struct {
  int *in;
  int *out;
} c_args_t;

// FOUR INDEPENDENT LCG streams so consecutive instructions are NOT dependent
// (instruction-level parallelism) -> the scheduler issues them back-to-back and
// the single issue slot stays busy -> high IPC. Moderate, un-unrolled loop so the
// kernel text stays small and ALL threads finish together before any ebreak
// (the previous huge unrolled version got cut short -> only thread 0 wrote).
static inline int churn(int a, int i) {
  unsigned s0 = (unsigned)a + 0x9e3779b9u;
  unsigned s1 = (unsigned)a ^ 0x85ebca6bu;
  unsigned s2 = (unsigned)(a + i) * 2654435761u;
  unsigned s3 = (unsigned)(a * 3 + 1);
  for (int j = 0; j < 512; j++) {
    s0 = s0 * 1664525u   + 1013904223u;   // 4 independent chains -> ILP
    s1 = s1 * 22695477u  + 1u;
    s2 = s2 * 1103515245u + 12345u;
    s3 = s3 * 214013u    + 2531011u;
  }
  return (int)(s0 ^ s1 ^ s2 ^ s3);
}

void compute_kernel(c_args_t *__UNIFORM__ args) {
  int i = blockIdx.x;
  args->out[i] = churn(args->in[i], i);
}

int in_buf[N];
volatile int out_buf[N];

int main() {
  for (int i = 0; i < N; i++) { in_buf[i] = i * 2654435761u + 1; out_buf[i] = 0; }

  c_args_t args;
  args.in  = in_buf;
  args.out = (int*)out_buf;

  uint32_t total = N;
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)compute_kernel, &args);

  int errors = 0;
  for (int i = 0; i < N; i++)
    if (out_buf[i] != churn(in_buf[i], i)) errors++;
  return errors;   // out_buf[] is the DUT-vs-SimX scoreboard check
}
