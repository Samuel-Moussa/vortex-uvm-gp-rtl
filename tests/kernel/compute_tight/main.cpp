// compute_tight — branchless, memory-free ALU kernel to drive high sustained IPC.
//
// Purpose: cover cp_ipc_bucket.high_ipc (windowed IPC 0.75..1.0), which is
// REACHABLE at single-issue (max IPC = 1.0) but not hit by the divergent/memory
// kernels (branch + cache bubbles cap them at ~med). Structure copies the
// PROVEN diverge_deep kernel (same vx_spawn_threads flow, N=64 so all lanes get
// multiple waves) but the per-thread work is a single straight-line basic block:
// FOUR independent LCG streams (ILP) in a no-unroll loop, no branches, no memory
// in the hot loop. With 4 warps hiding latency and no bubbles the scheduler
// issues nearly every cycle -> windowed IPC approaches 1.0 -> high_ipc bin.
// One load + one store per thread only, at the ends. printf-free (INV-1).

#include <vx_intrinsics.h>
#include <vx_spawn.h>

#define N 64

typedef struct {
  int *in;
  int *out;
} ct_args_t;

// Straight-line, branchless, 4 independent chains -> instruction-level parallelism.
static inline int tight(int v, int i) {
  unsigned a = (unsigned)v + 0x9e3779b9u;
  unsigned b = (unsigned)v ^ 0x85ebca6bu;
  unsigned c = (unsigned)(v + i) * 2654435761u;
  unsigned d = (unsigned)(v * 3 + 1);
  for (int k = 0; k < 300; k++) {
    a = a * 1664525u    + 1013904223u;
    b = b * 22695477u   + 1u;
    c = c * 1103515245u + 12345u;
    d = d * 214013u     + 2531011u;
  }
  return (int)(a ^ b ^ c ^ d);
}

int in_buf[N];
volatile int out_buf[N];

void tight_kernel(ct_args_t *__UNIFORM__ args) {
  int i = blockIdx.x;
  args->out[i] = tight(args->in[i], i);
}

int main() {
  for (int i = 0; i < N; i++) { in_buf[i] = i * 7 + 1; out_buf[i] = 0; }

  ct_args_t args;
  args.in  = in_buf;
  args.out = (int*)out_buf;

  uint32_t total = N;
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)tight_kernel, &args);

  int errors = 0;
  for (int i = 0; i < N; i++)
    if (out_buf[i] != tight(in_buf[i], i)) errors++;
  return errors;   // out_buf[] is the DUT-vs-SimX scoreboard check
}
