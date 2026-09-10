// fuzzgpu_repro -- W3-B (JSA_MACHINE_WORK_PACKAGE.md): repro attempts for the two
// FuzzGPU (USENIX Security '26) Vortex findings whose PoC is cheap to reproduce in
// this environment, at our pin (Vortex 7a52ee5 + 18 local RTL mods, OBS-040).
// FuzzGPU filed at commit 2189194; we run a different pin -- do not claim either
// direction without running it, which is exactly what this kernel does.
//
// X1 (upstream PR #356, "Fix FPU x0 writeback scoreboard"): VX_fpu_unit.sv
// unconditionally asserts `.data.wb = 1'b1` for every FPU result, including
// compare ops (feq.s/flt.s/fle.s) whose destination is architecturally x0.
// VX_scoreboard.sv does not reserve x0, so a later FPU writeback to x0 trips its
// "invalid writeback register" assertion and the RTL sim $finish-es. PoC is the
// PR's own conform-test sequence (do_feq_x0_scoreboard), reproduced verbatim.
// At our pin: `grep VX_fpu_unit.sv` shows the unconditional `wb = 1'b1` is still
// present (unfixed) -- see docs/RTL_OBSERVATIONS.md OBS-047 for the outcome.
//
// X2 (upstream PR #358, "Fix M-extension funct7 decoding"): sim/simx/decode.cpp
// decodes an R-type instruction as an M-extension op whenever `funct7 & 0x1`,
// instead of requiring the exact RV32M encoding `funct7 == 7'b0000001`. RTL
// (VX_decode.sv:178-194) always matched exactly (a `case` statement, no `&0x1`
// anywhere in the decode path) -- this was a SimX-only (golden-model) decode bug,
// not an RTL bug, despite being filed under "3 Vortex RTL bugs" in the paper's
// framing. At our pin, sim/simx/decode.cpp:648 still has the loose `&0x1` check.
// This PoC hand-encodes a RESERVED R-type opcode (opcode=0x33, funct3=0,
// funct7=0000011) that no real ISA extension defines. RTL decodes it as ADD
// (default case, funct7[5]=0); the unfixed SimX golden model decodes it as MUL
// (0x03 & 0x1 == 1). A single instruction with an unused encoding therefore has
// two different "correct" answers depending on which model executes it -- exactly
// the kind of golden-model defect our own lockstep/end-state scoreboard exists to
// catch. Expected outcome if reproduced: the scoreboard reports a MISMATCH, not a
// crash -- so this is NOT added to run_suite.sh (it is not meant to pass).
//
// X3 (upstream PR #359, "hw: fix WMMA fp16/bf16 RTL output handling") is NOT
// attempted here -- see docs/paper/PRESUBMISSION_DISCLOSURES.md Section 7 for the
// static-only disposition (building a working fp16/bf16-output WMMA kernel through
// this TB's TCU path is real engineering, not a cheap PoC port, and was out of
// scope for this pass).
//
// printf-free by design (INV-1): a vx_printf-heavy kernel here would make the
// wall-clock cost of finding out X1 crashes the sim needlessly large.

#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <vx_print.h>

#define N 4

typedef struct { int *out; } fr_args_t;

volatile int out_buf[N];   // out_buf[0] = X1 reached-canary, out_buf[1] = X2 .insn result

static int __attribute__((noinline)) make_full_tmask(int num_threads) {
  return (num_threads >= 32) ? -1 : ((1 << num_threads) - 1);
}

// ---- X1: feq.s x0, f24, f1 under a full thread mask (PR #356 PoC, verbatim) ----
static void __attribute__((noinline)) do_feq_x0_scoreboard() {
  __asm__ volatile(
    "fsgnj.s f24, f0, f0\n\t"
    "fsgnj.s f1, f0, f0\n\t"
    "feq.s x0, f24, f1\n\t"
    :
    :
    : "memory");
}

static int test_feq_x0_scoreboard() {
  int num_threads = vx_num_threads();
  if (num_threads > 4) num_threads = 4;
  int tmask = make_full_tmask(num_threads);
  vx_tmc(tmask);
  do_feq_x0_scoreboard();
  vx_tmc_one();
  // If we get here, the RTL did NOT $finish on the assertion -- record that the
  // instruction path was actually reached (distinguishes "not reproduced" from
  // "never executed").
  return 1;
}

// ---- X2: reserved R-type encoding, opcode=0x33 funct3=0 funct7=0000011 --------
// RTL-correct answer is ADD (funct7[5]=0, default case): 3 + 5 = 8.
// Unfixed-SimX answer (funct7 & 0x1 true) is MUL: 3 * 5 = 15.
static int test_reserved_funct7() {
  long rs1_val = 3, rs2_val = 5;
  long result;
  __asm__ volatile(
    "mv a1, %1\n\t"
    "mv a2, %2\n\t"
    ".insn r 0x33, 0, 0x03, a0, a1, a2\n\t"
    "mv %0, a0\n\t"
    : "=r"(result)
    : "r"(rs1_val), "r"(rs2_val)
    : "a0", "a1", "a2", "memory");
  return (int)result;
}

void fr_kernel(fr_args_t *__UNIFORM__ args) {
  args->out[0] = test_feq_x0_scoreboard();
  args->out[1] = test_reserved_funct7();
  args->out[2] = 0;
  args->out[3] = 0;
}

int main() {
  for (int i = 0; i < N; i++) out_buf[i] = -1;

  fr_args_t args;
  args.out = (int*)out_buf;

  uint32_t total = 1;
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)fr_kernel, &args);

  // Host-side note (not a pass/fail gate -- the point of this kernel IS to let the
  // TB's own DUT-vs-SimX compare surface any divergence on out_buf[1]):
  //   out_buf[0] == 1  -> X1's feq.s x0 path was reached without an RTL $finish
  //   out_buf[1] == 8  -> this run's RTL/SimX agreed on ADD (bug not exercised or
  //                       SimX happened to also decode it as ADD)
  //   out_buf[1] == 15 -> SimX decoded MUL while RTL (by construction) computed
  //                       ADD -> exactly the divergence X2 predicts
  return 0;
}
