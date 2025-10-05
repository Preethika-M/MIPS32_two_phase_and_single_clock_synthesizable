module mips32_test;

reg clk;
integer k;

// Instantiate DUT
mips DUT(clk);

// Clock generation
initial clk = 0;
always #5 clk = ~clk;  // 100MHz-ish simulation clock

// Program + initialization
initial begin
    // Clear registers
    for (k=0; k<32; k=k+1) DUT.regs[k] = 0;

    // Example program with hazards
    DUT.regs[1] = 10;      // Initial value
    DUT.Mem[10] = 50;      // Memory for load

    // Instructions (same as previous example)
    DUT.Mem[0] = {DUT.ADDI, 5'd1, 5'd2, 16'd5};
    DUT.Mem[1] = {DUT.SUB, 5'd2, 5'd1, 5'd3, 5'd0, 6'd0};
    DUT.Mem[2] = {DUT.LW, 5'd2, 5'd4, 16'd0};
    DUT.Mem[3] = {DUT.ADD, 5'd4, 5'd3, 5'd5, 5'd0, 6'd0};
    DUT.Mem[4] = {DUT.BEQZ, 5'd5, 5'd0, 16'd2};
    DUT.Mem[5] = {DUT.ADDI, 5'd0, 5'd6, 16'd99};
    DUT.Mem[6] = {DUT.ADDI, 5'd0, 5'd6, 16'd42};
    DUT.Mem[7] = {DUT.HLT, 26'd0};

    // Init CPU
    DUT.PC = 0;
    DUT.halted = 0;
    DUT.taken_branch = 0;
    DUT.stall = 0;

    // Run for enough time
    #500;

    // Dump registers
    $display("----- Register Dump -----");
    for (k=0;k<8;k=k+1)
        $display("R%0d = %0d", k, DUT.regs[k]);

    $finish;
end

endmodule
