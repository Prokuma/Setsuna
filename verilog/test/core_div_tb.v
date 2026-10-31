`timescale 1ns/1ps
module core_m_tb;
    reg clk = 0;
    reg reset = 1;
    wire instruction_valid;
    wire [63:0] instruction_address;
    reg [31:0] instruction_data;
    wire data_valid, data_write;
    wire [7:0] data_write_strobe;
    wire [63:0] data_address, data_write_data;
    reg [4:0] debug_address;
    wire [63:0] debug_data, cycles, retired;
    wire halted, trap;
    wire [63:0] trap_pc, trap_cause;
    reg [31:0] instructions [0:31];
    integer index;

    core #(.RESET_VECTOR(0), .ENABLE_M(1)) dut (
        .clk(clk), .reset(reset),
        .instruction_valid(instruction_valid), .instruction_address(instruction_address),
        .instruction_ready(1'b1), .instruction_data(instruction_data),
        .data_valid(data_valid), .data_write(data_write),
        .data_write_strobe(data_write_strobe), .data_address(data_address),
        .data_write_data(data_write_data), .data_ready(1'b1), .data_read_data(64'b0),
        .debug_register_address(debug_address), .debug_register_data(debug_data),
        .cycle_count(cycles), .retired_count(retired), .halted(halted), .trap(trap),
        .trap_pc(trap_pc), .trap_cause(trap_cause)
    );
    always #5 clk = ~clk;
    always @* instruction_data = instructions[instruction_address[6:2]];

    function [31:0] addi(input [4:0] rd, input [4:0] rs1, input integer imm);
        addi = {imm[11:0], rs1, 3'h0, rd, 7'h13};
    endfunction
    function [31:0] op(input [4:0] rd, input [4:0] rs1, input [4:0] rs2,
                       input [2:0] funct3, input [6:0] funct7);
        op = {funct7, rs2, rs1, funct3, rd, 7'h33};
    endfunction
    function [31:0] opw(input [4:0] rd, input [4:0] rs1, input [4:0] rs2,
                        input [2:0] funct3);
        opw = {7'h01, rs2, rs1, funct3, rd, 7'h3b};
    endfunction
    function [31:0] slli(input [4:0] rd, input [4:0] rs1, input [5:0] amount);
        slli = {6'b0, amount, rs1, 3'h1, rd, 7'h13};
    endfunction
    task check_register(input [4:0] number, input [63:0] expected);
        begin
            debug_address = number; #1;
            if (debug_data !== expected)
                $fatal(1, "x%0d expected %h, got %h", number, expected, debug_data);
        end
    endtask

    initial begin
        for (index = 0; index < 32; index = index + 1)
            instructions[index] = 32'h00000013;
        instructions[0] = addi(1, 0, -100);
        instructions[1] = addi(2, 0, 7);
        instructions[2] = op(3, 1, 2, 3'h4, 7'h01);   // DIV
        instructions[3] = op(4, 1, 2, 3'h6, 7'h01);   // REM
        instructions[4] = op(5, 3, 4, 3'h0, 7'h00);   // consumes both results
        instructions[5] = op(6, 1, 2, 3'h5, 7'h01);   // DIVU
        instructions[6] = op(7, 1, 2, 3'h7, 7'h01);   // REMU
        instructions[7] = op(8, 1, 0, 3'h4, 7'h01);   // DIV by zero
        instructions[8] = op(9, 1, 0, 3'h6, 7'h01);   // REM by zero
        instructions[9] = opw(10, 1, 2, 3'h4);         // DIVW
        instructions[10] = opw(11, 1, 2, 3'h6);        // REMW
        instructions[11] = opw(12, 1, 2, 3'h5);        // DIVUW
        instructions[12] = opw(13, 1, 2, 3'h7);        // REMUW
        instructions[13] = op(14, 1, 2, 3'h1, 7'h01); // MULH
        instructions[14] = op(15, 1, 2, 3'h2, 7'h01); // MULHSU
        instructions[15] = op(16, 1, 2, 3'h3, 7'h01); // MULHU
        instructions[16] = opw(17, 1, 2, 3'h0);        // MULW
        instructions[17] = addi(18, 0, 1);
        instructions[18] = slli(18, 18, 6'd63);
        instructions[19] = addi(19, 0, -1);
        instructions[20] = op(20, 18, 19, 3'h4, 7'h01); // signed overflow
        instructions[21] = op(21, 18, 19, 3'h6, 7'h01);
        instructions[22] = {20'h80000, 5'd22, 7'h37};  // -2^31
        instructions[23] = opw(23, 22, 19, 3'h4);       // word overflow
        instructions[24] = opw(24, 22, 19, 3'h6);
        instructions[25] = op(25, 2, 1, 3'h4, 7'h01); // positive / negative
        instructions[26] = op(26, 2, 1, 3'h6, 7'h01); // smaller dividend
        instructions[27] = op(27, 2, 19, 3'h4, 7'h01);
        instructions[28] = op(28, 2, 19, 3'h6, 7'h01);
        instructions[29] = 32'h00100073;               // EBREAK
        repeat (3) @(posedge clk); reset <= 0;
        repeat (1100) begin
            @(posedge clk);
            if (halted) begin
                if (trap) $fatal(1, "unexpected trap cause=%0d", trap_cause);
                check_register(3, -64'd14);
                check_register(4, -64'd2);
                check_register(5, -64'd16);
                check_register(6, 64'h2492492492492484);
                check_register(7, 0);
                check_register(8, ~64'b0);
                check_register(9, -64'd100);
                check_register(10, -64'd14);
                check_register(11, -64'd2);
                check_register(12, 64'h24924916);
                check_register(13, 2);
                check_register(14, ~64'b0);
                check_register(15, ~64'b0);
                check_register(16, 6);
                check_register(17, -64'd700);
                check_register(20, 64'h8000000000000000);
                check_register(21, 0);
                check_register(23, 64'hffffffff80000000);
                check_register(24, 0);
                check_register(25, 0);
                check_register(26, 7);
                check_register(27, -64'd7);
                check_register(28, 0);
                if (retired !== 30) $fatal(1, "expected 30 retired, got %0d", retired);
                $display("PASS: RV64M iterative DIV/REM, W variants, zero divisor, DSP multiplication, dependencies");
                $finish;
            end
        end
        $fatal(1, "core M test timed out");
    end
endmodule
