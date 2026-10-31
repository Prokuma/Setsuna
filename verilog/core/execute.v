`timescale 1ns/1ps
module execute #(
    parameter integer ENABLE_M = 1
) (
    input  wire [31:0] instruction,
    input  wire [63:0] pc,
    input  wire [63:0] operand_a,
    input  wire [63:0] operand_b,
    input  wire [63:0] immediate,
    input  wire [63:0] division_result,
    output reg  [63:0] result,
    output reg  [63:0] memory_address,
    output reg         redirect,
    output reg  [63:0] redirect_pc,
    output reg         illegal
);
    wire [6:0] opcode = instruction[6:0];
    wire [2:0] funct3 = instruction[14:12];
    wire [6:0] funct7 = instruction[31:25];
    wire [127:0] product = operand_a * operand_b;
    wire [63:0] mixed_product_high = product[127:64] -
        (operand_a[63] ? operand_b : 64'b0);
    wire [63:0] signed_product_high = mixed_product_high -
        (operand_b[63] ? operand_a : 64'b0);
    reg branch_taken;
    reg [63:0] word_value;

    always @* begin
        result = 64'b0;
        memory_address = operand_a + immediate;
        redirect = 1'b0;
        redirect_pc = 64'b0;
        illegal = 1'b0;
        branch_taken = 1'b0;
        word_value = 64'b0;
        case (opcode)
            7'h37: result = immediate;
            7'h17: result = pc + immediate;
            7'h6f: begin
                result = pc + 4;
                redirect = 1'b1;
                redirect_pc = pc + immediate;
            end
            7'h67: begin
                result = pc + 4;
                redirect = 1'b1;
                redirect_pc = (operand_a + immediate) & ~64'b1;
            end
            7'h63: begin
                case (funct3)
                    3'h0: branch_taken = operand_a == operand_b;
                    3'h1: branch_taken = operand_a != operand_b;
                    3'h4: branch_taken = $signed(operand_a) < $signed(operand_b);
                    3'h5: branch_taken = $signed(operand_a) >= $signed(operand_b);
                    3'h6: branch_taken = operand_a < operand_b;
                    3'h7: branch_taken = operand_a >= operand_b;
                    default: illegal = 1'b1;
                endcase
                redirect = branch_taken;
                redirect_pc = pc + immediate;
            end
            7'h03, 7'h23: memory_address = operand_a + immediate;
            7'h13: begin
                case (funct3)
                    3'h0: result = operand_a + immediate;
                    3'h2: result = $signed(operand_a) < $signed(immediate);
                    3'h3: result = operand_a < immediate;
                    3'h4: result = operand_a ^ immediate;
                    3'h6: result = operand_a | immediate;
                    3'h7: result = operand_a & immediate;
                    3'h1: begin
                        if (instruction[31:26] != 0) illegal = 1'b1;
                        result = operand_a << instruction[25:20];
                    end
                    3'h5: begin
                        if (!(instruction[31:26] == 0 || instruction[31:26] == 6'h10))
                            illegal = 1'b1;
                        result = instruction[30] ? $signed(operand_a) >>> instruction[25:20]
                                                 : operand_a >> instruction[25:20];
                    end
                endcase
            end
            7'h1b: begin
                case (funct3)
                    3'h0: word_value = operand_a + immediate;
                    3'h1: begin
                        if (funct7 != 0) illegal = 1'b1;
                        word_value = operand_a << instruction[24:20];
                    end
                    3'h5: begin
                        if (!(funct7 == 0 || funct7 == 7'h20)) illegal = 1'b1;
                        word_value = instruction[30] ? $signed(operand_a[31:0]) >>> instruction[24:20]
                                                     : operand_a[31:0] >> instruction[24:20];
                    end
                    default: illegal = 1'b1;
                endcase
                result = {{32{word_value[31]}}, word_value[31:0]};
            end
            7'h33: begin
                if (ENABLE_M && funct7 == 7'h01) begin
                    case (funct3)
                        3'h0: result = product[63:0];
                        3'h1: result = signed_product_high;
                        3'h2: result = mixed_product_high;
                        3'h3: result = product[127:64];
                        3'h4, 3'h5, 3'h6, 3'h7: result = division_result;
                    endcase
                end else if (funct7 == 0 || (funct7 == 7'h20 && (funct3 == 0 || funct3 == 5))) begin
                    case (funct3)
                        3'h0: result = funct7[5] ? operand_a - operand_b : operand_a + operand_b;
                        3'h1: result = operand_a << operand_b[5:0];
                        3'h2: result = $signed(operand_a) < $signed(operand_b);
                        3'h3: result = operand_a < operand_b;
                        3'h4: result = operand_a ^ operand_b;
                        3'h5: result = funct7[5] ? $signed(operand_a) >>> operand_b[5:0]
                                                 : operand_a >> operand_b[5:0];
                        3'h6: result = operand_a | operand_b;
                        3'h7: result = operand_a & operand_b;
                    endcase
                end else illegal = 1'b1;
            end
            7'h3b: begin
                if (ENABLE_M && funct7 == 7'h01) begin
                    case (funct3)
                        3'h0: word_value = product[31:0];
                        3'h4, 3'h5, 3'h6, 3'h7: word_value = division_result[31:0];
                        default: illegal = 1'b1;
                    endcase
                end else if (funct7 == 0 || (funct7 == 7'h20 && (funct3 == 0 || funct3 == 5))) begin
                    case (funct3)
                        3'h0: word_value = funct7[5] ? operand_a - operand_b : operand_a + operand_b;
                        3'h1: word_value = operand_a[31:0] << operand_b[4:0];
                        3'h5: word_value = funct7[5] ? $signed(operand_a[31:0]) >>> operand_b[4:0]
                                                    : operand_a[31:0] >> operand_b[4:0];
                        default: illegal = 1'b1;
                    endcase
                end else illegal = 1'b1;
                result = {{32{word_value[31]}}, word_value[31:0]};
            end
            7'h0f, 7'h73: result = 0;
            default: illegal = 1'b1;
        endcase
    end
endmodule
