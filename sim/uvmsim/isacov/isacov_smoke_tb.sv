// Standalone proof that riscvISACOV RV32I/BASIC elaborates and samples in
// QuestaSim 2021.2, with NOTHING from Vortex connected. Milestone 4 of the
// handover: "get it to elaborate before connecting anything."
`timescale 1ns/1ps

// Pull the class into THIS compilation unit. Compiling RISCV_coverage.svh as a
// separate file puts `coverage` in its own $unit package, which is not visible here.
`include "RISCV_coverage.svh"

module isacov_smoke_tb;

    localparam ILEN=32, XLEN=32, FLEN=32, VLEN=256, NHART=1, RETIRE=1;

    logic clk = 0;
    always #5 clk = ~clk;

    rvviTrace #(ILEN, XLEN, FLEN, VLEN, NHART, RETIRE) rvvi();

    // rvviTrace declares every field as `wire`, so a class cannot write it --
    // it has to be DRIVEN. This is the shape the real Vortex shim will need too.
    logic                     r_valid;
    logic [63:0]              r_order;
    logic [ILEN-1:0]          r_insn;
    logic [XLEN-1:0]          r_pc;
    logic [31:0]              r_x_wb;
    logic [31:0][XLEN-1:0]    r_x_wdata;

    assign rvvi.clk             = clk;
    assign rvvi.valid[0][0]     = r_valid;
    assign rvvi.order[0][0]     = r_order;
    assign rvvi.insn[0][0]      = r_insn;
    assign rvvi.pc_rdata[0][0]  = r_pc;
    assign rvvi.x_wb[0][0]      = r_x_wb;
    assign rvvi.x_wdata[0][0]   = r_x_wdata;
    assign rvvi.trap[0][0]      = 1'b0;
    assign rvvi.halt[0][0]      = 1'b0;
    assign rvvi.intr[0][0]      = 1'b0;
    assign rvvi.mode[0][0]      = 2'b11;   // M-mode: Vortex has no other mode
    assign rvvi.ixl[0][0]       = 2'b01;   // XLEN=32
    assign rvvi.pc_wdata[0][0]  = '0;
    assign rvvi.f_wb[0][0]      = '0;
    assign rvvi.f_wdata[0][0]   = '0;
    assign rvvi.v_wb[0][0]      = '0;
    assign rvvi.v_wdata[0][0]   = '0;
    assign rvvi.csr_wb[0][0]    = '0;
    assign rvvi.csr[0][0]       = '0;
    assign rvvi.lrsc_cancel[0][0] = 1'b0;
    assign rvvi.debug_mode[0][0]  = 1'b0;
    assign rvvi.mode_virt         = 1'b0;

    coverage #(ILEN, XLEN, FLEN, VLEN, NHART, RETIRE) cov;

    // One retirement: publish the record, let the model sample it.
    task automatic retire(input logic [31:0] insn,
                          input logic [31:0] pc,
                          input int          rd,
                          input logic [31:0] value,
                          input string       disass);
        @(negedge clk);
        r_insn    = insn;
        r_pc      = pc;
        r_x_wb    = (rd == 0) ? 32'b0 : (32'b1 << rd);   // x0 never writes back
        r_x_wdata = '0;
        r_x_wdata[rd] = value;
        r_valid   = 1'b1;
        r_order   = r_order + 1;
        @(posedge clk);
        cov.sample(1'b0, 0, 0, disass);
        @(negedge clk);
        r_valid   = 1'b0;
    endtask

    initial begin
        r_valid = 0; r_order = 0; r_insn = 0; r_pc = 0;
        r_x_wb = 0; r_x_wdata = '0;
        cov = new(rvvi);

        // Real RV32I encodings, hand-assembled and checked field by field.
        retire(32'h00A00293, 32'h80000000, 5, 32'd10,          "00a00293 addi x5,x0,10");
        retire(32'h00528333, 32'h80000004, 6, 32'd20,          "00528333 add x6,x5,x5");
        retire(32'h405303B3, 32'h80000008, 7, 32'hFFFFFFF6,    "405303b3 sub x7,x6,x5");
        retire(32'h00A00293, 32'h8000000C, 5, 32'd0,           "00a00293 addi x5,x0,10");

        $display("[SMOKE] 4 retirements sampled");
        #20 $finish;
    end

endmodule
