module mips32_test;

reg clk;
integer k;

// Instantiate DUT
mips DUT(
    .clk(clk),
    .out_result(),
    .out_PC(),
    .halted_out()
);

// Clock generation
initial clk = 0;
always #5 clk = ~clk;  // 100MHz-ish simulation clock

// Program + initialization
initial begin
    // Clear registers
    for (k=0; k<32; k=k+1) DUT.regs[k] = 0;

    // Example initial values
    DUT.regs[1] = 10;      // Initial value in R1
    DUT.Mem[10] = 50;      // Memory for load instruction

    // Instructions (32-bit encoding)
    // Format: opcode + rs + rt + rd/imm depending on type
    DUT.Mem[0] = {DUT.ADDI, 5'd1, 5'd2, 16'd5};            // R2 = R1 + 5
    DUT.Mem[1] = {DUT.SUB, 5'd2, 5'd1, 5'd3, 5'd0, 6'd0};   // R3 = R2 - R1
    DUT.Mem[2] = {DUT.LW, 5'd2, 5'd4, 16'd0};              // R4 = Mem[R2+0]
    DUT.Mem[3] = {DUT.ADD, 5'd4, 5'd3, 5'd5, 5'd0, 6'd0};   // R5 = R4 + R3
    DUT.Mem[4] = {DUT.BEQZ, 5'd5, 5'd0, 16'd2};             // if(R5==0) skip next 2
    DUT.Mem[5] = {DUT.ADDI, 5'd0, 5'd6, 16'd99};            // R6 = 99
    DUT.Mem[6] = {DUT.ADDI, 5'd0, 5'd6, 16'd42};            // R6 = 42
    DUT.Mem[7] = {DUT.HLT, 26'd0};                          // halt

    // Initialize CPU control signals
    DUT.PC = 0;
    DUT.halted = 0;
    DUT.taken_branch = 0;
    DUT.stall = 0;

    // Run simulation for enough time for instructions to execute
    #500;

    // Dump first 8 registers
    $display("----- Register Dump -----");
    for (k=0;k<8;k=k+1)
        $display("R%0d = %0d", k, DUT.regs[k]);

    // Dump observable outputs
    $display("----- CPU Outputs -----");
    $display("PC = %0d", DUT.out_PC);
    $display("ALU Result = %0d", DUT.out_result);
    $display("Halted = %b", DUT.halted_out);

    $finish;
end

endmodule
