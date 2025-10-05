module mips(clk);

input clk;

reg [31:0] PC, IF_ID_IR, IF_ID_NPC;
reg [31:0] ID_EX_IR, ID_EX_NPC, ID_EX_A, ID_EX_B, ID_EX_Imm;
reg [2:0]  ID_EX_type, EX_MEM_type, MEM_WB_type;
reg [31:0] EX_MEM_A, EX_MEM_B, EX_MEM_ALUOUT, EX_MEM_IR;
reg        EX_MEM_cond;
reg [31:0] MEM_WB_IR, MEM_WB_ALUOUT, MEM_WB_LMD;

reg halted, taken_branch;
reg stall;

reg [31:0] regs[0:31];
reg [31:0] Mem[0:1023];

parameter ADD = 6'b000000, SUB = 6'b000001, MUL = 6'b000010, DIV = 6'b000011,
          ADDI = 6'b000100, SUBI = 6'b000101, AND = 6'b000110, ANDI = 6'b000111,
          HLT = 6'b001000, NOR = 6'b001001, NOT = 6'b001010, OR = 6'b001011,
          ORI = 6'b001100, XOR = 6'b001101, BEQZ = 6'b001110, XORI = 6'b001111,
          MOVN = 6'b010000, MOVE = 6'b010010, NEGU = 6'b010011,
          LW = 6'b010100, SW = 6'b010101, BNEQZ = 6'b010110;

parameter RR_ALU=3'b000, RM_ALU = 3'b001, LOAD = 3'b010, STORE = 3'b011, 
          BRANCH = 3'b100, HALT = 3'b101, NOP = 3'b110;

// --- helper function to get destination register ---
function [4:0] dest_reg;
    input [2:0] typ;
    input [31:0] ir;
    begin
        case(typ)
            RR_ALU: dest_reg = ir[15:11];
            RM_ALU: dest_reg = ir[20:16];
            LOAD:   dest_reg = ir[20:16];
            default: dest_reg = 5'b00000;
        endcase
    end
endfunction

// --- IF Stage ---
always @(posedge clk) begin
    if (!halted) begin
        if (stall) begin
            PC <= PC;
            IF_ID_IR <= IF_ID_IR;
            IF_ID_NPC <= IF_ID_NPC;
        end else if ((EX_MEM_cond && EX_MEM_IR[31:26]==BEQZ) || (!EX_MEM_cond && EX_MEM_IR[31:26]==BNEQZ)) begin
            IF_ID_IR <= Mem[EX_MEM_ALUOUT];
            IF_ID_NPC <= EX_MEM_ALUOUT + 1;
            PC <= EX_MEM_ALUOUT + 1;
            taken_branch <= 1;
        end else begin
            IF_ID_IR <= Mem[PC];
            IF_ID_NPC <= PC + 1;
            PC <= PC + 1;
            taken_branch <= 0;
        end
    end
end

// --- ID Stage + Hazard Detection ---
always @(posedge clk) begin
    if (!halted) begin
        ID_EX_A <= (IF_ID_IR[25:21]==0)?0:regs[IF_ID_IR[25:21]];
        ID_EX_B <= (IF_ID_IR[20:16]==0)?0:regs[IF_ID_IR[20:16]];
        ID_EX_NPC <= IF_ID_NPC;
        ID_EX_IR <= IF_ID_IR;
        ID_EX_Imm <= {{16{IF_ID_IR[15]}},IF_ID_IR[15:0]};

        case(IF_ID_IR[31:26])
            ADD,SUB,AND,OR,NOT,XOR,NEGU,MUL,DIV,MOVE,MOVN: ID_EX_type <= RR_ALU;
            ADDI,SUBI,ANDI,ORI,XORI: ID_EX_type <= RM_ALU;
            LW: ID_EX_type <= LOAD;
            SW: ID_EX_type <= STORE;
            BNEQZ,BEQZ: ID_EX_type <= BRANCH;
            HLT: ID_EX_type <= HALT;
            default: ID_EX_type <= HALT;
        endcase

        // load-use hazard
        stall <= 0;
        if (ID_EX_type == LOAD) begin
            if ((ID_EX_IR[20:16]!=0) && ((ID_EX_IR[20:16]==IF_ID_IR[25:21])||(ID_EX_IR[20:16]==IF_ID_IR[20:16]))) begin
                stall <= 1;
                ID_EX_type <= NOP;
                ID_EX_IR <= 0;
                ID_EX_A <= 0;
                ID_EX_B <= 0;
                ID_EX_Imm <= 0;
            end
        end
    end
end

// --- EX Stage + Forwarding ---
always @(posedge clk) begin
    if(!halted) begin
        EX_MEM_type <= ID_EX_type;
        EX_MEM_IR <= ID_EX_IR;
        taken_branch <= 0;

        reg [31:0] opA, opB;
        reg [4:0] dest_exmem, dest_memwb;
        reg [31:0] val_exmem, val_memwb;

        dest_exmem = dest_reg(EX_MEM_type, EX_MEM_IR);
        val_exmem = (EX_MEM_type==RR_ALU || EX_MEM_type==RM_ALU)? EX_MEM_ALUOUT:0;

        dest_memwb = dest_reg(MEM_WB_type, MEM_WB_IR);
        val_memwb = (MEM_WB_type==LOAD)? MEM_WB_LMD:MEM_WB_ALUOUT;

        opA = ID_EX_A;
        opB = ID_EX_B;

        if ((dest_exmem!=0)&&(dest_exmem==ID_EX_IR[25:21])&&(EX_MEM_type==RR_ALU||EX_MEM_type==RM_ALU))
            opA = val_exmem;
        else if ((dest_memwb!=0)&&(dest_memwb==ID_EX_IR[25:21])&&(MEM_WB_type==RR_ALU||MEM_WB_type==RM_ALU||MEM_WB_type==LOAD))
            opA = val_memwb;

        if(ID_EX_type==RR_ALU) begin
            if ((dest_exmem!=0)&&(dest_exmem==ID_EX_IR[20:16])&&(EX_MEM_type==RR_ALU||EX_MEM_type==RM_ALU))
                opB = val_exmem;
            else if ((dest_memwb!=0)&&(dest_memwb==ID_EX_IR[20:16])&&(MEM_WB_type==RR_ALU||MEM_WB_type==RM_ALU||MEM_WB_type==LOAD))
                opB = val_memwb;
        end

        case(ID_EX_type)
            RR_ALU: begin
                case(ID_EX_IR[31:26])
                    ADD: EX_MEM_ALUOUT <= opA + opB;
                    SUB: EX_MEM_ALUOUT <= opA - opB;
                    AND: EX_MEM_ALUOUT <= opA & opB;
                    OR:  EX_MEM_ALUOUT <= opA | opB;
                    NOT: EX_MEM_ALUOUT <= ~opA;
                    XOR: EX_MEM_ALUOUT <= opA ^ opB;
                    NEGU: EX_MEM_ALUOUT <= -opA;
                    MUL: EX_MEM_ALUOUT <= opA * opB;
                    DIV: EX_MEM_ALUOUT <= opA / opB;
                    MOVE: EX_MEM_ALUOUT <= opA;
                    MOVN: EX_MEM_ALUOUT <= -opA;
                endcase
            end
            RM_ALU: begin
                case(ID_EX_IR[31:26])
                    ADDI: EX_MEM_ALUOUT <= opA + ID_EX_Imm;
                    SUBI: EX_MEM_ALUOUT <= opA - ID_EX_Imm;
                    ANDI: EX_MEM_ALUOUT <= opA & ID_EX_Imm;
                    ORI:  EX_MEM_ALUOUT <= opA | ID_EX_Imm;
                    XORI: EX_MEM_ALUOUT <= opA ^ ID_EX_Imm;
                endcase
            end
            LOAD, STORE: begin
                EX_MEM_ALUOUT <= ID_EX_A & ID_EX_Imm;
                EX_MEM_B <= ID_EX_B;
            end
            BRANCH: begin
                EX_MEM_ALUOUT <= ID_EX_NPC & ID_EX_Imm;
                EX_MEM_cond <= (opA==0);
            end
        endcase
    end
end

// --- MEM Stage ---
always @(posedge clk) begin
    if(!halted) begin
        MEM_WB_type <= EX_MEM_type;
        MEM_WB_IR <= EX_MEM_IR;
        case(EX_MEM_type)
            RR_ALU, RM_ALU: MEM_WB_ALUOUT <= EX_MEM_ALUOUT;
            LOAD: MEM_WB_LMD <= Mem[EX_MEM_ALUOUT];
            STORE: if(!taken_branch) Mem[EX_MEM_ALUOUT] <= EX_MEM_B;
        endcase
    end
end

// --- WB Stage ---
always @(posedge clk) begin
    if(!taken_branch) begin
        case(MEM_WB_type)
            RR_ALU: regs[MEM_WB_IR[15:11]] <= MEM_WB_ALUOUT;
            RM_ALU: regs[MEM_WB_IR[20:16]] <= MEM_WB_ALUOUT;
            LOAD: regs[MEM_WB_IR[20:16]] <= MEM_WB_LMD;
            HALT: halted <= 1;
        endcase
    end
end

endmodule
