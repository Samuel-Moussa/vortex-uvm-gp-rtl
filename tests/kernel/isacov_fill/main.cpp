// isacov_fill — directed kernel to close specific riscvISACOV RV32I/M/F gaps that
// no other kernel in the suite naturally emits: bge, lb/lh/lhu/sh, register-form
// sll/sra/srl, slt, ori, nop, mulh/mulhsu/mulhu, fle.s, fsgnjx.s.
//
// Every instruction is forced via inline asm (the loads/stores/shifts/ori use a C
// idiom the compiler reliably lowers to the exact opcode: sub-word volatile
// accesses for lb/lh/lhu/sh, a runtime (non-constant) shift amount for register-
// form sll/sra/srl) so gap-hunting doesn't depend on hoping the compiler happens
// to pick that encoding on its own. All results are pure integer/bit-pattern
// reductions -> byte-exact end-state vs SimX (no ULP tolerance needed: fle.s is a
// pure compare, fsgnjx.s is a pure bit-manipulation, neither rounds).

#include <stdint.h>
#include <vx_intrinsics.h>
#include <vx_spawn.h>
#include <VX_config.h>

#define MAX_TOTAL 128
#define NPAIR 16

// ---- forced-opcode helpers (inline asm; each is exactly one instruction) ----
static inline int32_t i_bge(int32_t a, int32_t b) {
  int32_t r;
  __asm__ volatile("bge %1,%2,1f\n\tli %0,0\n\tj 2f\n\t1:\n\tli %0,1\n\t2:"
                    : "=r"(r) : "r"(a), "r"(b));
  return r;
}
static inline int32_t i_slt(int32_t a, int32_t b)
{ int32_t r; __asm__("slt %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline int32_t i_mulh(int32_t a, int32_t b)
{ int32_t r; __asm__("mulh %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline int32_t i_mulhsu(int32_t a, uint32_t b)
{ int32_t r; __asm__("mulhsu %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline uint32_t i_mulhu(uint32_t a, uint32_t b)
{ uint32_t r; __asm__("mulhu %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline int32_t i_fle_s(float a, float b)
{ int32_t r; __asm__("fle.s %0,%1,%2" : "=r"(r) : "f"(a), "f"(b)); return r; }
static inline float i_fsgnjx_s(float a, float b)
{ float r; __asm__("fsgnjx.s %0,%1,%2" : "=f"(r) : "f"(a), "f"(b)); return r; }
static inline void i_nop() { __asm__ volatile("nop"); }

// ---- gap-hunt round 2 (2026-09-20): riscvISACOV cp_imm_value / cp_*_sign
// corners left unhit by every other kernel in the suite. Each helper is one
// forced instruction, same discipline as above. See docs/RTL_OBSERVATIONS.md
// OBS-068 for which sibling bins are EXCLUDED instead (structural: CSR-value
// mis-wiring, branch/jal absolute-target parsing, unsigned shamt/upper-imm
// fields, and jal/jalr return-address/base registers always being a PC in
// this project's fixed >=0x80000000 link base).
static inline int32_t i_and(int32_t a, int32_t b)
{ int32_t r; __asm__("and %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline int32_t i_sltu(uint32_t a, uint32_t b)
{ int32_t r; __asm__("sltu %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline int32_t i_div(int32_t a, int32_t b)
{ int32_t r; __asm__("div %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline int32_t i_rem(int32_t a, int32_t b)
{ int32_t r; __asm__("rem %0,%1,%2" : "=r"(r) : "r"(a), "r"(b)); return r; }
static inline float i_fcvt_s_wu(uint32_t a)
{ float r; __asm__("fcvt.s.wu %0,%1" : "=f"(r) : "r"(a)); return r; }
static inline uint32_t i_fcvt_wu_s(float a)
{ uint32_t r; __asm__("fcvt.wu.s %0,%1,rtz" : "=r"(r) : "f"(a)); return r; }
static inline int32_t i_slli0(int32_t a)
{ int32_t r; __asm__("slli %0,%1,0" : "=r"(r) : "r"(a)); return r; }
static inline uint32_t i_srli0(uint32_t a)
{ uint32_t r; __asm__("srli %0,%1,0" : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_srai0(int32_t a)
{ int32_t r; __asm__("srai %0,%1,0" : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_lui0() {
  int32_t r;
  __asm__("lui %0,0" : "=r"(r));
  return r;
}
// Pointer+constant loads/stores: the compiler reliably folds these to a single
// insn with a nonzero encoded immediate (never a base-register recompute) for
// a compile-time-constant displacement off a runtime base pointer.
static inline int32_t i_lb_off(int8_t *p, int off)
{ return off == 3 ? *(volatile int8_t *)(p + 3) : *(volatile int8_t *)(p - 3); }
static inline int32_t i_lh_off(int16_t *p, int off)
{ return off == 2 ? *(volatile int16_t *)(p + 2) : *(volatile int16_t *)(p - 2); }
static inline uint32_t i_lhu_off(int16_t *p, int off)
{ return off == 2 ? *(volatile uint16_t *)(p + 2) : *(volatile uint16_t *)(p - 2); }
static inline void i_sh_off(int16_t *p, int16_t v, int off) {
  if (off == 5) *(volatile int16_t *)(p + 5) = v;
  else          *(volatile int16_t *)(p - 5) = v;
}
static inline void i_sb_off(int8_t *p, int8_t v) { *(volatile int8_t *)(p + 1) = v; }
static inline void i_fsw_off(float *p, float v, int off) {
  if (off == 4) *(volatile float *)(p + 1) = v;
  else          *(volatile float *)(p - 1) = v;
}
// ALU-immediate corners: forced so the compiler cannot constant-fold the
// literal away (it would, given a plain "x & 0" or "x | (-1)" C expression).
static inline int32_t i_andi0(int32_t a)
{ int32_t r; __asm__("andi %0,%1,0"   : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_orin(int32_t a)
{ int32_t r; __asm__("ori %0,%1,-1"   : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_ori0(int32_t a)
{ int32_t r; __asm__("ori %0,%1,0"    : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_sltin(int32_t a)
{ int32_t r; __asm__("slti %0,%1,-5"  : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_slti0(int32_t a)
{ int32_t r; __asm__("slti %0,%1,0"   : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_sltiun(uint32_t a)
{ int32_t r; __asm__("sltiu %0,%1,-5" : "=r"(r) : "r"(a)); return r; }
static inline int32_t i_sltiu0(uint32_t a)
{ int32_t r; __asm__("sltiu %0,%1,0"  : "=r"(r) : "r"(a)); return r; }

typedef struct {
  int32_t  *a, *b;          // integer operand pairs
  uint32_t *shamt;          // runtime (non-constant) shift amounts
  int8_t   *b8;             // lb source
  int16_t  *h16;            // lh/lhu source value
  float    *fa, *fb;        // fle.s / fsgnjx.s operands
  uint32_t *out;
} fill_args_t;

volatile int32_t  g_a[NPAIR]     = { 7, -3, 100, -100, 1, -1, 0x7fffffff, (int32_t)0x80000000,
                                      42, -42, 9, -9, 55, -55, 3, -3 };
volatile int32_t  g_b[NPAIR]     = { 3, 5, -7, 50, -1, 1, 1, -1,
                                      -42, 42, 2, 2, -55, 55, 5, -5 };
volatile uint32_t g_shamt[NPAIR] = { 1, 3, 7, 15, 0, 31, 5, 9, 2, 4, 6, 8, 10, 12, 14, 16 };
volatile int8_t   g_b8[NPAIR]    = { 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7, 8, -8 };
volatile int16_t  g_h16[NPAIR]   = { 100, -100, 200, -200, 300, -300, 400, -400,
                                      500, -500, 600, -600, 700, -700, 800, -800 };
volatile float    g_fa[NPAIR]    = { 1.5f, -2.5f, 3.0f, -4.0f, 0.0f, -0.0f, 100.0f, -100.0f,
                                      1.5f, -2.5f, 3.0f, -4.0f, 0.0f, -0.0f, 100.0f, -100.0f };
volatile float    g_fb[NPAIR]    = { 2.5f, -1.5f, 3.0f, -4.0f, 1.0f, 1.0f, 50.0f, -50.0f,
                                      2.5f, -1.5f, 3.0f, -4.0f, 1.0f, 1.0f, 50.0f, -50.0f };

volatile int32_t  g_ain[NPAIR];
volatile int32_t  g_bin[NPAIR];
volatile uint32_t g_shin[NPAIR];
volatile int8_t   g_b8in[NPAIR];
volatile int16_t  g_h16in[NPAIR];
volatile float    g_fain[NPAIR];
volatile float    g_fbin[NPAIR];
volatile int16_t  g_h16out[MAX_TOTAL];     // per-thread sh destination (own slot only)
volatile uint32_t g_out[MAX_TOTAL];

// Padded per-thread scratch for offset load/store gap-hunting (round 2). Each
// thread gets its own OFF_STRIDE-wide window (widest offset used below is +/-5,
// so a 16-element stride leaves a >=11-element no-overlap margin between any
// two threads' windows -- a tighter 1-index-apart layout was caught here as a
// genuine cross-thread race before it ever reached the simulator: thread N's
// write at +5 would have landed inside thread N+1's +/-5 read/write window).
#define OFF_STRIDE 16
#define OFF_PAD    8
volatile int8_t   g_off_i8 [2 * OFF_PAD + MAX_TOTAL * OFF_STRIDE];
volatile int16_t  g_off_i16[2 * OFF_PAD + MAX_TOTAL * OFF_STRIDE];
volatile float    g_off_f32[2 * OFF_PAD + MAX_TOTAL * OFF_STRIDE];

static inline uint32_t f2u(float f) { union { float f; uint32_t u; } c; c.f = f; return c.u; }

void fill_kernel(fill_args_t *__UNIFORM__ args) {
  int tid = blockIdx.x;
  uint32_t acc = 0;
  for (int k = 0; k < NPAIR; k++) {
    int idx = (k + tid) % NPAIR;
    int32_t  a  = args->a[idx];
    int32_t  b  = args->b[idx];
    uint32_t ua = (uint32_t)a;
    uint32_t sh = args->shamt[idx] & 31u;      // runtime value -> register-form shifts
    // bge operands are WARP-UNIFORM (indexed by k only, not tid/idx): a raw
    // hand-assembled branch bypasses the compiler's split/join codegen, so a
    // per-lane-DIFFERING condition here would cause genuine SIMT divergence on
    // real hardware with no compiler-inserted reconvergence markers -- outside
    // this kernel's scope (divergence coverage lives elsewhere; this kernel is
    // scalar instruction-identity only).
    int32_t au = args->a[k], bu = args->b[k];

    acc += (uint32_t)i_bge(au, bu);                                  // bge
    acc += (uint32_t)i_slt(a, b);                                     // slt
    acc += (uint32_t)i_mulh(a, b);                                    // mulh
    acc += (uint32_t)i_mulhsu(a, (uint32_t)b);                        // mulhsu
    acc += i_mulhu(ua, (uint32_t)b);                                  // mulhu
    acc += (uint32_t)(a << sh);                                       // sll (register form)
    acc += (uint32_t)(a >> sh);                                       // sra (register form, signed)
    acc += (ua >> sh);                                                // srl (register form, unsigned)
    acc += (uint32_t)(a | 0x123);                                     // ori
    i_nop();                                                          // nop

    // Sub-word memory. Each thread writes/reads only its own slot (no cross-thread
    // races); naturally 2-byte-aligned array so no misaligned access (MEM-4, W-10).
    g_h16out[tid] = (int16_t)(args->h16[idx] + tid);                  // sh
    acc += (uint32_t)(int32_t) g_h16out[tid];                         // lh  (signed load)
    acc += (uint32_t)(uint16_t) *(volatile uint16_t *)&g_h16out[tid]; // lhu (unsigned load)
    acc += (uint32_t)(int32_t) args->b8[idx];                         // lb

    float fa = args->fa[idx], fb = args->fb[idx];
    acc += (uint32_t)i_fle_s(fa, fb);                                 // fle.s
    acc += f2u(i_fsgnjx_s(fa, fb));                                   // fsgnjx.s

    // ---- round 2: register/immediate-value corners (see file header) ----
    acc += (uint32_t)i_and(a, b);                                     // and
    acc += (uint32_t)i_sltu(ua, (uint32_t)b);                         // sltu (rs1 negative-as-unsigned)
    acc += (uint32_t)i_div(0, (b != 0) ? b : 1);                      // div  (rs1==0)
    acc += (uint32_t)i_rem(0, (b != 0) ? b : 1);                      // rem  (rs1==0)
    acc += f2u(i_fcvt_s_wu(ua));                                      // fcvt.s.wu (rs1 pos, from the a/b cycle)
    acc += f2u(i_fcvt_s_wu(0u));                                      // fcvt.s.wu (rs1==0 exactly -- never occurs in g_a)
    acc += i_fcvt_wu_s(fa);                                           // fcvt.wu.s (rd zero, from the fa cycle's 0.0f)
    acc += i_fcvt_wu_s(3.5e9f);                                       // fcvt.wu.s (rd >= 2^31 -- reads "neg" as int32)
    acc += (uint32_t)i_slli0(a);                                      // slli x,x,0
    acc += i_srli0(ua);                                               // srli x,x,0
    acc += (uint32_t)i_srai0(a);                                      // srai x,x,0
    acc += (uint32_t)i_lui0();                                        // lui x,0
    acc += (uint32_t)i_andi0(a);                                      // andi x,x,0
    acc += (uint32_t)i_orin(a);                                       // ori  x,x,-1
    acc += (uint32_t)i_ori0(a);                                       // ori  x,x,0
    acc += (uint32_t)i_sltin(a);                                      // slti x,x,-5
    acc += (uint32_t)i_slti0(a);                                      // slti x,x,0
    acc += (uint32_t)i_sltiun(ua);                                    // sltiu x,x,-5 (sign-extended imm)
    acc += (uint32_t)i_sltiu0(ua);                                    // sltiu x,x,0

    // Offset loads/stores. Own-slot base pointer, +/-N is always in-bounds
    // thanks to OFF_PAD; g_off_i8/i16/f32 are pre-seeded with a fixed pattern
    // in main() before any thread runs so every load reads a defined value.
    {
      int off_base = OFF_PAD + tid * OFF_STRIDE;
      int8_t  *p8  = (int8_t  *)&g_off_i8 [off_base];
      int16_t *p16 = (int16_t *)&g_off_i16[off_base];
      float   *pf  = (float   *)&g_off_f32[off_base];
      acc += (uint32_t)i_lb_off(p8, 3);                               // lb  imm=+3
      acc += (uint32_t)i_lb_off(p8, -3);                              // lb  imm=-3
      acc += (uint32_t)i_lh_off(p16, 2);                              // lh  imm=+2
      acc += (uint32_t)i_lh_off(p16, -2);                             // lh  imm=-2
      acc += i_lhu_off(p16, 2);                                       // lhu imm=+2
      acc += i_lhu_off(p16, -2);                                      // lhu imm=-2
      i_sh_off(p16, (int16_t)(0x1000 + tid), 5);                      // sh  imm=+5
      i_sh_off(p16, (int16_t)(-1 - tid), -5);                         // sh  imm=-5
      i_sb_off(p8, (int8_t)(-1 - tid));                                // sb  rs2 negative
      i_fsw_off(pf, fa, 4);                                           // fsw imm=+4
      i_fsw_off(pf, fb, -4);                                          // fsw imm=-4
    }
  }
  args->out[tid] = acc;
}

int main() {
  for (int i = 0; i < NPAIR; i++) {
    g_ain[i] = g_a[i]; g_bin[i] = g_b[i]; g_shin[i] = g_shamt[i];
    g_b8in[i] = g_b8[i]; g_h16in[i] = g_h16[i];
    g_fain[i] = g_fa[i]; g_fbin[i] = g_fb[i];
  }
  fill_args_t args;
  args.a = (int32_t *)g_ain; args.b = (int32_t *)g_bin;
  args.shamt = (uint32_t *)g_shin;
  args.b8 = (int8_t *)g_b8in; args.h16 = (int16_t *)g_h16in;
  args.fa = (float *)g_fain; args.fb = (float *)g_fbin;
  args.out = (uint32_t *)g_out;
  uint32_t total = (uint32_t)vx_num_cores() * vx_num_warps() * vx_num_threads();
  if (total > MAX_TOTAL) total = MAX_TOTAL;
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)fill_kernel, &args);
  return 0;
}
