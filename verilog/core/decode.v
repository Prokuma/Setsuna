`timescale 1ns/1ps
module decode (
    input  wire [31:0] instruction,
    output wire [6:0]  opcode,
    output wire [2:0]  funct3,
    output wire [6:0]  funct7,
    output wire [4:0]  rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output reg  [63:0] immediate,
    output reg         uses_rs1,
    output reg         uses_rs2,
    output reg         writes_rd,
    output reg         memory_read,
    output reg         memory_write,
    output reg         illegal
);
    assign opcode = instruction[6:0];
    assign rd = instruction[11:7];
    assign funct3 = instruction[14:12];
    assign rs1 = instruction[19:15];
    assign rs2 = instruction[24:20];
    assign funct7 = instruction[31:25];

    always @* begin
        immediate = 64'b0;
        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;
        writes_rd = 1'b0;
        memory_read = 1'b0;
        memory_write = 1'b0;
        illegal = 1'b0;
        case (opcode)
            7'h37, 7'h17: begin
                writes_rd = 1'b1;
                immediate = {{32{instruction[31]}}, instruction[31:12], 12'b0};
            end
            7'h6f: begin
                writes_rd = 1'b1;
                immediate = {{43{instruction[31]}}, instruction[31], instruction[19:12],
                             instruction[20], instruction[30:21], 1'b0};
            end
            7'h67: begin
                uses_rs1 = 1'b1;
                writes_rd = 1'b1;
                immediate = {{52{instruction[31]}}, instruction[31:20]};
                if (funct3 != 0) illegal = 1'b1;
            end
            7'h63: begin
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
                immediate = {{51{instruction[31]}}, instruction[31], instruction[7],
                             instruction[30:25], instruction[11:8], 1'b0};
                if (!(funct3 == 0 || funct3 == 1 || funct3 == 4 || funct3 == 5 ||
                      funct3 == 6 || funct3 == 7)) illegal = 1'b1;
            end
            7'h03: begin
                uses_rs1 = 1'b1;
                writes_rd = 1'b1;
                memory_read = 1'b1;
                immediate = {{52{instruction[31]}}, instruction[31:20]};
                if (funct3 == 7) illegal = 1'b1;
            end
            7'h23: begin
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
                memory_write = 1'b1;
                immediate = {{52{instruction[31]}}, instruction[31:25], instruction[11:7]};
                if (funct3 > 3) illegal = 1'b1;
            end
            7'h13: begin
                uses_rs1 = 1'b1;
                writes_rd = 1'b1;
                immediate = {{52{instruction[31]}}, instruction[31:20]};
            end
            7'h1b: begin
                uses_rs1 = 1'b1;
                writes_rd = 1'b1;
                immediate = {{52{instruction[31]}}, instruction[31:20]};
                if (!(funct3 == 0 || funct3 == 1 || funct3 == 5)) illegal = 1'b1;
            end
            7'h33, 7'h3b: begin
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
                writes_rd = 1'b1;
            end
            7'h0f: begin
                if (!(funct3 == 0 || funct3 == 1)) illegal = 1'b1;
            end
            7'h73: begin
                if (!(instruction == 32'h00100073 || instruction == 32'h00000073))
                    illegal = 1'b1;
            end
            default: illegal = 1'b1;
        endcase
    end
endmodule
