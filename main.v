module mips(clk1,clk2);

input clk1,clk2;

reg [31:0] PC, IF_ID_IR, IF_ID_NPC;
reg [31:0] ID_EX_IR, ID_EX_NPC, ID_EX_A, ID_EX_B, ID_EX_Imm;
reg [2:0]  ID_EX_type,EX_MEM_type,MEM_WB_type;
reg [31:0] EX_MEM_A, EX_MEM_B, EX_MEM_ALUOUT, EX_MEM_IR;
reg 		  EX_MEM_cond;
reg [31:0] MEM_WB_IR, MEM_WB_ALUOUT, MEM_WB_LMD;

reg halted, taken_branch;

// register file & memory
reg [31:0] regs[0:31];
reg [31:0] Mem[0:1023];

parameter ADD = 6'b000000, SUB = 6'b000001, MUL = 6'b000010, DIV = 6'b000011,
             ADDI = 6'b000100, SUBI = 6'b000101, AND = 6'b000110, ANDI = 6'b000111,
             HLT = 6'b001000, NOR = 6'b001001, NOT = 6'b001010, OR = 6'b001011,
             ORI = 6'b001100, XOR = 6'b001101, BEQZ = 6'b001110, XORI = 6'b001111,
             MOVN = 6'b010000, MOVE = 6'b010010, NEGU = 6'b010011,
             LW = 6'b010100, SW = 6'b010101, BNEQZ = 6'b010110;
             
parameter RR_ALU=3'b000, RM_ALU = 3'b001, LOAD = 3'b010, STORE = 3'b011, BRANCH = 3'b100, HALT = 3'b101, NOP = 3'b110;


// internal stall signal for load-use hazard
reg stall;  

// helper: get destination register depending on type and IR
function [4:0] dest_reg;
    input [2:0] typ;
    input [31:0] ir;
    begin
        case(typ)
            RR_ALU: dest_reg = ir[15:11];  // rd
            RM_ALU: dest_reg = ir[20:16];  // rt (immediate dest)
            LOAD:   dest_reg = ir[20:16];  // rt
            default: dest_reg = 5'b00000;
        endcase
    end
endfunction

// --- IF stage (clk1)
always @(posedge clk1)
begin
    if (halted == 0)
        begin
            if (stall) // if stall asserted (load-use), freeze IF/ID and PC (do not fetch new)
                begin
                    // keep IF_ID_IR and IF_ID_NPC unchanged; PC unchanged
                    IF_ID_IR <= IF_ID_IR;
                    IF_ID_NPC <= IF_ID_NPC;
                    PC <= PC;
                end
            else if((EX_MEM_cond == 1 && EX_MEM_IR[31:26] == BEQZ)||(EX_MEM_cond == 0 && EX_MEM_IR[31:26] == BNEQZ))
                    begin
                    // branch was resolved in EX -> fetch from branch target
                    IF_ID_IR <= Mem[EX_MEM_ALUOUT];	
                    taken_branch <= 1'b1;
                    IF_ID_NPC <= EX_MEM_ALUOUT+1;
                    PC <= EX_MEM_ALUOUT+1;
                    end
            else
                    begin
                    IF_ID_IR <= Mem[PC];
                    IF_ID_NPC <= PC+1;
                    PC <= PC+1;
                    end
        end
end

// --- ID Stage (clk2)  + hazard detection
always @(posedge clk2)
begin
    if(halted ==0)
        begin
        // default: clear stall; we will set it if we detect a load-use hazard
        stall <= 1'b0;

        // Read register operands (if source is $0, give 0)
        if(IF_ID_IR[25:21] == 5'b00000)
            ID_EX_A<=0;
        else
            ID_EX_A<= regs[IF_ID_IR[25:21]];
            
        if(IF_ID_IR[20:16] == 5'b00000)
            ID_EX_B<=0;
        else
            ID_EX_B<= regs[IF_ID_IR[20:16]];
            
        ID_EX_NPC <= IF_ID_NPC;
        ID_EX_IR <= IF_ID_IR;
        ID_EX_Imm <= {{16{IF_ID_IR[15]}},{IF_ID_IR[15:0]}};
        
        case(IF_ID_IR[31:26])
            ADD,SUB,AND,OR,NOT,XOR,NEGU,MUL,DIV,MOVE,MOVN: ID_EX_type <= RR_ALU;
            ADDI,SUBI,ANDI,ORI,XORI: ID_EX_type <= RM_ALU;
            LW:ID_EX_type <= LOAD;
            SW: ID_EX_type <= STORE;
            BNEQZ,BEQZ: ID_EX_type <= BRANCH;
            HLT: ID_EX_type <= HALT;
            default: ID_EX_type <= HALT;
        endcase

        // ----- Load-use hazard detection -----
        // If the instruction currently in ID/EX is a LOAD and its destination matches
        // either source register (rs or rt) of the instruction currently in IF/ID,
        // then we must stall one cycle (insert a bubble).
        if (ID_EX_type == LOAD) begin
            // dest of load is ID_EX_IR[20:16], sources of current IF_ID are IF_ID_IR[25:21] and IF_ID_IR[20:16]
            if ((ID_EX_IR[20:16] != 5'b00000) && 
                ((ID_EX_IR[20:16] == IF_ID_IR[25:21]) || (ID_EX_IR[20:16] == IF_ID_IR[20:16])))
            begin
                stall <= 1'b1;
                // Insert bubble into ID/EX: convert this cycle's update into a NOP
                ID_EX_type <= NOP;
                ID_EX_IR <= 32'b0;
                ID_EX_A <= 32'b0;
                ID_EX_B <= 32'b0;
                ID_EX_Imm <= 32'b0;
            end
        end

        end
end

// --- EX Stage (clk1) with forwarding
always @(posedge clk1)
    if(halted==0)
    begin
        EX_MEM_type<= ID_EX_type;
        EX_MEM_IR <= ID_EX_IR;
        taken_branch <= 0;
        
        // compute forwarded operand A and B (default from ID/EX)
        reg [31:0] opA, opB;
        reg [4:0] dest_exmem, dest_memwb;
        reg [31:0] val_exmem, val_memwb;
        
        // determine destinations and values available to forward
        // EX/MEM forwarding (only when EX/MEM has ALU result types)
        dest_exmem = dest_reg(EX_MEM_type, EX_MEM_IR);
        if ((EX_MEM_type == RR_ALU) || (EX_MEM_type == RM_ALU))
            val_exmem = EX_MEM_ALUOUT;
        else
            val_exmem = 32'b0;
        
        // MEM/WB forwarding (ALU or LOAD)
        dest_memwb = dest_reg(MEM_WB_type, MEM_WB_IR);
        if (MEM_WB_type == LOAD)
            val_memwb = MEM_WB_LMD;
        else
            val_memwb = MEM_WB_ALUOUT;

        // default operands from ID/EX
        opA = ID_EX_A;
        opB = ID_EX_B;

        // Forward to opA if needed
        if ((dest_exmem != 5'b00000) && (dest_exmem == ID_EX_IR[25:21]) && ((EX_MEM_type == RR_ALU) || (EX_MEM_type == RM_ALU)))
            opA = val_exmem;
        else if ((dest_memwb != 5'b00000) && (dest_memwb == ID_EX_IR[25:21]) && ((MEM_WB_type == RR_ALU) || (MEM_WB_type == RM_ALU) || (MEM_WB_type == LOAD)))
            opA = val_memwb;

        // Forward to opB if needed (for RR_ALU operands), for RM_ALU opB is immediate
        if (ID_EX_type == RR_ALU) begin
            if ((dest_exmem != 5'b00000) && (dest_exmem == ID_EX_IR[20:16]) && ((EX_MEM_type == RR_ALU) || (EX_MEM_type == RM_ALU)))
                opB = val_exmem;
            else if ((dest_memwb != 5'b00000) && (dest_memwb == ID_EX_IR[20:16]) && ((MEM_WB_type == RR_ALU) || (MEM_WB_type == RM_ALU) || (MEM_WB_type == LOAD)))
                opB = val_memwb;
        end

        // Now perform ALU operations using opA/opB (or imm when RM_ALU)
        case(ID_EX_type)
            RR_ALU: begin
                        case(ID_EX_IR[31:26])
                            ADD: EX_MEM_ALUOUT <= opA + opB;
                            SUB: EX_MEM_ALUOUT <= opA - opB;
                            AND: EX_MEM_ALUOUT <= opA & opB;
                            OR : EX_MEM_ALUOUT <= opA | opB;
                            NOT: EX_MEM_ALUOUT <= ~(opA);
                            XOR: EX_MEM_ALUOUT <= opA ^ opB;
                            NEGU: EX_MEM_ALUOUT <= -(opA);
                            MUL: EX_MEM_ALUOUT <= opA * opB;
                            DIV: EX_MEM_ALUOUT <= opA / opB;
                            MOVE: EX_MEM_ALUOUT <= opA;
                            MOVN: EX_MEM_ALUOUT <= -(opA);
                        endcase
                      end
                      
            RM_ALU: begin
                        case(ID_EX_IR[31:26])
                            ADDI: EX_MEM_ALUOUT <= opA + ID_EX_Imm;
                            SUBI: EX_MEM_ALUOUT <= opA - ID_EX_Imm;
                            ANDI: EX_MEM_ALUOUT <= opA & ID_EX_Imm;
                            ORI : EX_MEM_ALUOUT <= opA | ID_EX_Imm;
                            XORI: EX_MEM_ALUOUT <= opA ^ ID_EX_Imm;
                        endcase
                      end
                      
            LOAD,STORE: begin
                        // For address computation the design originally did bitwise AND -> kept same
                        EX_MEM_ALUOUT <= ID_EX_A & ID_EX_Imm;
                        // store value for SW. But SW value may need forwarding too in complicated designs;
                        // We forward store data from forwarding path if necessary in MEM stage if desired.
                        EX_MEM_B <= ID_EX_B;
                     end
                     
            BRANCH: begin
                        EX_MEM_ALUOUT <= ID_EX_NPC & ID_EX_Imm;
                        EX_MEM_cond <= (ID_EX_A == 0);
                      end
            NOP: begin
                        EX_MEM_ALUOUT <= 32'b0;
                        EX_MEM_cond <= 0;
                 end
        endcase            
    end
    
// --- MEM stage (clk2)
always @(posedge clk2)
    if(halted == 0)
    begin
    MEM_WB_type <= EX_MEM_type;
    MEM_WB_IR <= EX_MEM_IR;
    
    case(EX_MEM_type)
        RR_ALU, RM_ALU :  MEM_WB_ALUOUT <= EX_MEM_ALUOUT;
        LOAD:             MEM_WB_LMD <= Mem[EX_MEM_ALUOUT];
        STORE:            if(taken_branch == 0) Mem[EX_MEM_ALUOUT] <= EX_MEM_B;
        default: begin end
    endcase
    end

// --- WB stage (clk1)
always @(posedge clk1)
    begin
        if(taken_branch==0)
            case(MEM_WB_type)
                RR_ALU: regs[MEM_WB_IR[15:11]] <= MEM_WB_ALUOUT;
                RM_ALU: regs[MEM_WB_IR[20:16]] <= MEM_WB_ALUOUT;
                LOAD:   regs[MEM_WB_IR[20:16]] <= MEM_WB_LMD;
                HALT:   halted <= 1'b1;
                default: ; // NOP/HALT handled
            endcase
    end

endmodule

