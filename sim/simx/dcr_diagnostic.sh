#!/bin/bash
################################################################################
# DCR Diagnostic Script
# Helps identify DCR configuration issues in Vortex SimX integration
################################################################################

VORTEX_HOME="${VORTEX_HOME:-/home/stev_teto_22/vortex}"

echo "================================================================================"
echo "  Vortex SimX DCR Diagnostics"
echo "================================================================================"
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_file() {
    if [ -f "$1" ]; then
        echo -e "${GREEN}✓${NC} Found: $1"
        return 0
    else
        echo -e "${RED}✗${NC} Missing: $1"
        return 1
    fi
}

check_symbol() {
    local file=$1
    local symbol=$2
    if grep -q "$symbol" "$file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $symbol defined in $file"
        grep "$symbol" "$file" | head -3
        return 0
    else
        echo -e "${YELLOW}⚠${NC} $symbol NOT found in $file"
        return 1
    fi
}

echo "1. Checking Vortex Installation"
echo "================================"
if [ ! -d "$VORTEX_HOME" ]; then
    echo -e "${RED}ERROR: VORTEX_HOME not found: $VORTEX_HOME${NC}"
    echo "Set VORTEX_HOME environment variable or edit this script"
    exit 1
fi
echo -e "${GREEN}✓${NC} VORTEX_HOME: $VORTEX_HOME"
echo ""

echo "2. Checking Critical Header Files"
echo "=================================="
VX_CONFIG="$VORTEX_HOME/hw/rtl/VX_config.vh"
VX_TYPES="$VORTEX_HOME/hw/VX_types.h"
VX_DEFINE="$VORTEX_HOME/hw/VX_define.vh"

check_file "$VX_CONFIG"
check_file "$VX_TYPES"
check_file "$VX_DEFINE"
echo ""

echo "3. Checking DCR Definitions in Headers"
echo "======================================="
echo ""
echo "--- Checking VX_types.h ---"
if [ -f "$VX_TYPES" ]; then
    check_symbol "$VX_TYPES" "VX_DCR_BASE_STARTUP_ADDR"
    check_symbol "$VX_TYPES" "VX_DCR_BASE_STATE"
    check_symbol "$VX_TYPES" "VX_DCR_BASE_MPM_CLASS"
else
    echo -e "${RED}Cannot check - file not found${NC}"
fi
echo ""

echo "--- Checking VX_define.vh ---"
if [ -f "$VX_DEFINE" ]; then
    check_symbol "$VX_DEFINE" "VX_DCR_BASE_STATE_BEGIN"
    check_symbol "$VX_DEFINE" "VX_DCR_BASE_STATE_END"
    check_symbol "$VX_DEFINE" "VX_DCR_BASE_STATE_COUNT"
else
    echo -e "${RED}Cannot check - file not found${NC}"
fi
echo ""

echo "4. Checking SimX Build"
echo "======================"
SIMX_DIR="$VORTEX_HOME/sim/simx"
check_file "$SIMX_DIR/Makefile"
if [ -d "$SIMX_DIR/obj" ]; then
    echo -e "${GREEN}✓${NC} SimX object directory exists"
    OBJ_COUNT=$(find "$SIMX_DIR/obj" -name "*.o" | wc -l)
    echo "  Found $OBJ_COUNT object files"
    if [ $OBJ_COUNT -eq 0 ]; then
        echo -e "${YELLOW}⚠ WARNING: No object files found!${NC}"
        echo "  Build SimX: cd $SIMX_DIR && make"
    fi
else
    echo -e "${RED}✗${NC} SimX not built - missing obj directory"
    echo "  Run: cd $SIMX_DIR && make"
fi
echo ""

echo "5. Checking DCR-Related Source Files"
echo "====================================="
check_file "$SIMX_DIR/dcrs.h"
check_file "$SIMX_DIR/dcrs.cpp"
check_file "$SIMX_DIR/processor.h"
check_file "$SIMX_DIR/processor.cpp"
echo ""

echo "6. Analyzing DCR Usage in dcrs.cpp"
echo "==================================="
DCRS_CPP="$SIMX_DIR/dcrs.cpp"
if [ -f "$DCRS_CPP" ]; then
    echo "DCR write function:"
    grep -A 10 "void DCRS::write" "$DCRS_CPP" 2>/dev/null || echo "Function not found"
    echo ""
    echo "DCR address checks:"
    grep "VX_DCR_BASE" "$DCRS_CPP" 2>/dev/null || echo "No DCR base checks found"
else
    echo -e "${RED}Cannot analyze - file not found${NC}"
fi
echo ""

echo "7. Extracting DCR Address Values"
echo "================================="
if [ -f "$VX_TYPES" ]; then
    echo "From VX_types.h:"
    grep -E "define.*VX_DCR.*ADDR|define.*VX_DCR.*STATE" "$VX_TYPES" 2>/dev/null | head -20
fi
echo ""

echo "8. Checking Third-Party Dependencies"
echo "====================================="
RAMULATOR="$VORTEX_HOME/third_party/ramulator"
if [ -f "$RAMULATOR/libramulator.so" ] || [ -f "$RAMULATOR/libramulator.a" ]; then
    echo -e "${GREEN}✓${NC} Ramulator library found"
else
    echo -e "${YELLOW}⚠${NC} Ramulator library not found"
    echo "  May need to build: cd $RAMULATOR && make"
fi

SOFTFLOAT="$VORTEX_HOME/third_party/softfloat/build/Linux-x86_64-GCC/softfloat.a"
check_file "$SOFTFLOAT"
echo ""

echo "9. Recommended DCR Address Configuration"
echo "========================================="
echo "Based on standard Vortex configuration:"
echo ""
echo "  VX_DCR_BASE_STATE_BEGIN  = 0x001"
echo "  VX_DCR_BASE_STATE_END    = 0x041"
echo "  VX_DCR_BASE_STARTUP_ADDR0 = 0x800"
echo "  VX_DCR_BASE_STARTUP_ADDR1 = 0x801"
echo ""
echo "Your test should configure:"
echo "  simx_dcr_write(0x800, startup_addr[31:0]);  // Lower 32 bits"
echo "  simx_dcr_write(0x801, startup_addr[63:32]); // Upper 32 bits (if 64-bit)"
echo ""

echo "10. Build Command Verification"
echo "==============================="
echo "Recommended build command:"
echo ""
echo "g++ -std=c++17 -fPIC -shared -Wall \\"
echo "    -I\$QUESTA_HOME/include \\"
echo "    -I$VORTEX_HOME/sim/simx \\"
echo "    -I$VORTEX_HOME/sim/common \\"
echo "    -I$VORTEX_HOME/hw \\"
echo "    -I$VORTEX_HOME/hw/rtl \\"
echo "    -I$VORTEX_HOME/hw/rtl/libs \\"
echo "    -I$VORTEX_HOME/third_party/softfloat/source/include \\"
echo "    -I$VORTEX_HOME/third_party/ramulator/src \\"
echo "    -DXLEN_32 -DNUM_CORES=2 -DNUM_WARPS=4 -DNUM_THREADS=4 \\"
echo "    simx_dpi.cpp \\"
echo "    $SIMX_DIR/obj/*.o $SIMX_DIR/obj/common/*.o \\"
echo "    $VORTEX_HOME/third_party/softfloat/build/Linux-x86_64-GCC/softfloat.a \\"
echo "    -L$VORTEX_HOME/third_party/ramulator -lramulator \\"
echo "    -o simx_model.so"
echo ""

echo "================================================================================"
echo "  Diagnostic Complete"
echo "================================================================================"
echo ""
echo "Next Steps:"
echo "1. If SimX not built: cd $SIMX_DIR && make"
echo "2. Update simx_dpi.cpp with fixed DCR handling (provided in artifact)"
echo "3. Rebuild: make clean && make build"
echo "4. Test: make test_simple_postmortem"
echo ""
echo "For detailed DCR analysis, check:"
echo "  cat $VX_TYPES | grep DCR"
echo "  cat $DCRS_CPP"
echo ""
