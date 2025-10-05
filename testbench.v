
module mips32_test;

  reg clk1, clk2;
  integer k;

  // Instantiate DUT
  mips DUT(clk1, clk2);

  // Clock generation
  initial begin
    clk1 = 0; clk2 = 0;
    forever begin
      #5 clk1 = 1; #5 clk1 = 0;   // clk1 pulse
      #5 clk2 = 1; #5 clk2 = 0;   // clk2 pulse
    end
  end

  // Program + initialization
  initial begin
    // Clear registers
    for (k = 0; k < 32; k = k + 1)
      DUT.regs[k] = 0;

    // Example program with hazards
    // Encoding assumes your opcode parameters, here written symbolically:
    // R[1] = 10
    DUT.regs[1] = 10;

    // Mem[10] = 50 (data for load test)
    DUT.Mem[10] = 50;

    // Program in instruction memory:
    // 0: ADDI R2, R1, #5    ; R2 = R1 + 5   (depends on R1 init)
    DUT.Mem[0] = {mips.ADDI, 5'd1, 5'd2, 16'd5};

    // 1: SUB  R3, R2, R1    ; hazard, needs R2 result (forwarded)
    DUT.Mem[1] = {mips.SUB, 5'd2, 5'd1, 5'd3, 5'd0, 6'd0};

    // 2: LW   R4, 0(R2)     ; load Mem[R2] -> R4
    DUT.Mem[2] = {mips.LW, 5'd2, 5'd4, 16'd0};

    // 3: ADD  R5, R4, R3    ; hazard: uses loaded R4 next cycle (stall)
    DUT.Mem[3] = {mips.ADD, 5'd4, 5'd3, 5'd5, 5'd0, 6'd0};

    // 4: BEQZ R5, offset=2  ; if R5==0, branch
    DUT.Mem[4] = {mips.BEQZ, 5'd5, 5'd0, 16'd2};

    // 5: ADDI R6, R0, #99   ; skipped if branch taken
    DUT.Mem[5] = {mips.ADDI, 5'd0, 5'd6, 16'd99};

    // 6: ADDI R6, R0, #42   ; branch target
    DUT.Mem[6] = {mips.ADDI, 5'd0, 5'd6, 16'd42};

    // 7: HLT
    DUT.Mem[7] = {mips.HLT, 26'd0};

    // Init PC and state
    DUT.PC = 0;
    DUT.halted = 0;
    DUT.taken_branch = 0;

    // Run for some time
    #500;

    // Dump register results
    $display("----- Register Dump -----");
    for (k = 0; k < 8; k = k + 1)
      $display("R%0d = %0d", k, DUT.regs[k]);

    $finish;
  end

endmodule
```
