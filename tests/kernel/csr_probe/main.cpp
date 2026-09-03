// csr_probe — full Zicsr operation surface, safely, on every core.
//
// WHY THIS EXISTS.
// The riscvISACOV RV32Zicsr bank has six covergroups (csrrw/csrrs/csrrc and their
// immediate forms). Measured across ALL 47 kernel ELFs in this tree, by
// disassembling every one and histogramming the mnemonics:
//     csrrs  4439      csrrw    74      csrrsi  41
//     csrrwi   10      csrrc     6      csrrci   0
// So csrrci has NO producer anywhere in the suite and csrrc has almost none:
// rv32zicsr_csrrci_cg could never leave 0%, and csrrc_cg is starved. Everything
// the corpus does reach comes from crt0 / vx_intrinsics reading GPU id CSRs.
//
// WHICH FORM THE COMPILER EMITS. vx_intrinsics.h:53-89 selects the immediate
// form via __builtin_constant_p: a literal operand gives csrrwi/csrrsi/csrrci,
// a runtime value gives csrrw/csrrs/csrrc. This kernel deliberately uses both,
// and forces the register form with an optimisation barrier so constant folding
// cannot quietly turn it back into the immediate form.
//
// WHICH CSRs ARE SAFE, AND WHY ONLY THESE.
// Writing arbitrary M-mode CSRs is NOT safe here: the RTL asserts on csrw to
// 0x301/0x305, which is why prepare.sh sed-strips those from riscv-dv programs.
// This kernel touches only FRM (0x002) and FFLAGS (0x001) — the same two
// sfu_masks already uses, handled by SimX in emulator.cpp set_csr/get_csr, so
// DUT and golden agree. FRM is written only with values 0..3: 5 and 6 are
// RESERVED rounding modes and must never be programmed.
//
// SCOREBOARD SAFETY (the same discipline as sfu_masks):
//   * every CSR read result is folded as (x & 0), so out_buf NEVER depends on
//     fcsr. fcsr is per-warp, so a multi-thread CSR write has hardware-defined
//     conflict resolution that need not match SimX; folding makes the compared
//     memory state independent of it.
//   * no FP arithmetic here, so changing FRM cannot perturb any rounding, and
//     FFLAGS is restored to 0 at the end of every task so nothing downstream
//     inherits a dirty flag state.
//   * every thread writes ONLY its own out_buf[i]; vx_spawn distributes tasks
//     CONTIGUOUSLY (vx_spawn.c:299), so no core touches another's slice and no
//     barrier is needed (OBS-026).
//   * out_buf is .bss and is NOT zeroed here — a whole-array init would wipe
//     another core's results once every core is active (OBS-026).
//   * the result is a PURE function of (i, tid), recomputed identically on the
//     host side, so the compare is as strong as the device run.
//   * printf-free (INV-1).

#include <vx_intrinsics.h>
#include <vx_spawn.h>

#define MAX_TOTAL  128       // 8 cores x 16 threads/core
#define CSR_FFLAGS 0x001
#define CSR_FRM    0x002

#define OPQ(x) __asm__ volatile("" : "+r"(x))   // block constant folding

typedef struct { int *out; } cp_args_t;

// Register-form ops with an EXPLICIT rd and rs1, so cp_rd_reg_assign /
// cp_rs1_reg_assign see more than whatever the allocator happened to pick.
// Only caller-saved temporaries are named, and both are declared clobbered.
#define CSR_RW_REG(csr, rd, rs, val)                                      \
  __asm__ volatile("mv " rs ", %0\n\tcsrrw " rd ", %1, " rs               \
                   : : "r"(val), "i"(csr) : rd, rs)
#define CSR_RS_REG(csr, rd, rs, val)                                      \
  __asm__ volatile("mv " rs ", %0\n\tcsrrs " rd ", %1, " rs               \
                   : : "r"(val), "i"(csr) : rd, rs)
#define CSR_RC_REG(csr, rd, rs, val)                                      \
  __asm__ volatile("mv " rs ", %0\n\tcsrrc " rd ", %1, " rs               \
                   : : "r"(val), "i"(csr) : rd, rs)

static inline int cp_body(int i, int tid) {
  int r = i * 5 + 3;
  unsigned v;

  // ---- IMMEDIATE forms: csrrwi / csrrsi / csrrci -------------------------
  // Distinct uimm values, including 0, so cp_imm_value sees both its `zero`
  // and `pos` bins. (`neg` is structurally unreachable: the CSR immediate is a
  // 5-bit UNSIGNED field, so no Zicsr immediate-form covergroup can ever fill
  // it. Left honestly uncovered rather than faked.)
  v = csr_swap(CSR_FRM, 1);              OPQ(v); r += (int)(v & 0);  // csrrwi uimm=1
  v = csr_swap(CSR_FRM, 0);              OPQ(v); r += (int)(v & 0);  // csrrwi uimm=0
  v = csr_read_set(CSR_FFLAGS, 31);      OPQ(v); r += (int)(v & 0);  // csrrsi uimm=31
  v = csr_read_set(CSR_FFLAGS, 0);       OPQ(v); r += (int)(v & 0);  // csrrsi uimm=0
  v = csr_read_clear(CSR_FFLAGS, 21);    OPQ(v); r += (int)(v & 0);  // csrrci uimm=21
  v = csr_read_clear(CSR_FFLAGS, 0);     OPQ(v); r += (int)(v & 0);  // csrrci uimm=0
  v = csr_read_clear(CSR_FFLAGS, 31);    OPQ(v); r += (int)(v & 0);  // csrrci uimm=31

  // ---- REGISTER forms with spread rd/rs1 ---------------------------------
  unsigned m3 = (unsigned)(r & 0x3);   OPQ(m3);   // runtime => register form
  unsigned m5 = (unsigned)(r & 0x1f);  OPQ(m5);
  CSR_RW_REG(CSR_FRM,    "t0", "t1", m3);
  CSR_RW_REG(CSR_FRM,    "a4", "a5", (unsigned)(tid & 0x3));
  CSR_RS_REG(CSR_FFLAGS, "t2", "t3", m5);
  CSR_RS_REG(CSR_FFLAGS, "a6", "a7", (unsigned)((tid + 1) & 0x1f));
  CSR_RC_REG(CSR_FFLAGS, "t4", "t5", m5);
  CSR_RC_REG(CSR_FFLAGS, "t6", "t1", 0x1fu);

  // ---- READ-ONLY GPU CSRs: csrrs with rs1 = x0 ---------------------------
  // The common form in real code, and the one that gives cp_rs1_reg_assign its
  // x0 bin. Value-folded: thread/warp ids differ per lane and must not reach
  // out_buf, or the compare would stop being a pure function of (i, tid).
  v = (unsigned)vx_thread_id();  OPQ(v); r += (int)(v & 0);
  v = (unsigned)vx_warp_id();    OPQ(v); r += (int)(v & 0);
  v = (unsigned)vx_num_warps();  OPQ(v); r += (int)(v & 0);

  // Leave FRM at RNE and FFLAGS clear, so nothing downstream inherits state.
  v = csr_swap(CSR_FRM, 0);              OPQ(v); r += (int)(v & 0);
  v = csr_read_clear(CSR_FFLAGS, 31);    OPQ(v); r += (int)(v & 0);

  r += tid;
  OPQ(r);
  return r;
}

// Host-side reference. Every CSR result above is folded to zero by construction,
// so the reference needs no CSR access at all -- which is exactly the property
// that makes the compare independent of per-warp fcsr resolution.
static int cp_ref(int i, int tid) {
  return i * 5 + 3 + tid;
}

volatile int out_buf[MAX_TOTAL];

static int g_nt = 4;   // threads per warp, captured before the spawn

void cp_kernel(cp_args_t *__UNIFORM__ args) {
  int i = blockIdx.x;
  args->out[i] = cp_body(i, i % g_nt);
}

int main() {
  int nt = vx_num_threads();
  if (nt < 1) nt = 1;
  g_nt = nt;

  cp_args_t args; args.out = (int*)out_buf;

  // Device-sized grid: every core executes the full CSR surface.
  uint32_t total = (uint32_t)vx_num_cores() * vx_num_warps() * vx_num_threads();
  if (total > MAX_TOTAL) total = MAX_TOTAL;
  vx_spawn_threads(1, &total, nullptr, (vx_kernel_func_cb)cp_kernel, &args);

  // Check ONLY this core's contiguous slice (vx_spawn.c:299) — no barrier needed.
  uint32_t nc = (uint32_t)vx_num_cores(), cid = (uint32_t)vx_core_id();
  uint32_t per = total / nc, lo = cid * per, hi = lo + per;
  int errors = 0;
  for (uint32_t i = lo; i < hi; i++)
    if (out_buf[i] != cp_ref((int)i, (int)(i % (uint32_t)nt))) errors++;
  return errors;
}
