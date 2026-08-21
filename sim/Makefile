ROOT_DIR := $(realpath ..)
include $(ROOT_DIR)/config.mk

simx:
	$(MAKE) -C simx

# QuestaSim/UVM verification backend. Requires a licensed QuestaSim install
# and a RISC-V toolchain, so it is deliberately NOT part of `all` (unlike
# simx/rtlsim/opaesim/xrtsim, which only need open toolchains) — opt in with
# `make -C sim uvmsim` or from within sim/uvmsim/ directly (see its README).
uvmsim:
	$(MAKE) -C uvmsim help

all:
	$(MAKE) -C simx
	$(MAKE) -C rtlsim
	$(MAKE) -C opaesim
	$(MAKE) -C xrtsim

clean:
	$(MAKE) -C simx clean
	$(MAKE) -C rtlsim clean
	$(MAKE) -C opaesim clean
	$(MAKE) -C xrtsim clean
	$(MAKE) -C uvmsim clean