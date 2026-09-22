`timescale 1ns/1ps
module core_tb;
    reg clk = 0;
    reg reset = 1;
    wire instruction_valid;
    wire [63:0] instruction_address;
    reg instruction_ready = 1;
    reg [31:0] instruction_data;
    wire data_valid, data_write;
    wire [7:0] data_write_strobe;
    wire [63:0] data_address, data_write_data;
    reg data_ready = 0;
    reg [63:0] data_read_data = 0;
    reg [4:0] debug_address;
    wire [63:0] debug_data, cycles, retired;
    wire halted, trap;
    wire [63:0] trap_pc, trap_cause;
    reg [31:0] instructions [0:31];
    reg [63:0] memory [0:31];
    integer wait_cycles = 0;
    integer index;

    core #(.RESET_VECTOR(0)) dut (
        .clk(clk), .reset(reset),
        .instruction_valid(instruction_valid), .instruction_address(instruction_address),
        .instruction_ready(instruction_ready), .instruction_data(instruction_data),
        .data_valid(data_valid), .data_write(data_write),
        .data_write_strobe(data_write_strobe), .data_address(data_address),
        .data_write_data(data_write_data), .data_ready(data_ready), .data_read_data(data_read_data),
        .debug_register_address(debug_address), .debug_register_data(debug_data),
        .cycle_count(cycles), .retired_count(retired), .halted(halted), .trap(trap),
        .trap_pc(trap_pc), .trap_cause(trap_cause)
    );
    always #5 clk = ~clk;
    always @* instruction_data = instructions[instruction_address[6:2]];

    always @(posedge clk) begin
        data_ready <= 0;
        if (data_valid) begin
            if (wait_cycles == 2) begin
                data_ready <= 1;
                data_read_data <= memory[data_address[7:3]];
                if (data_write)
                    for (index = 0; index < 8; index = index + 1)
                        if (data_write_strobe[index])
                            memory[data_address[7:3]][index*8 +: 8] <= data_write_data[index*8 +: 8];
                wait_cycles <= 0;
            end else wait_cycles <= wait_cycles + 1;
        end else wait_cycles <= 0;
    end

    function [31:0] addi(input [4:0] rd, input [4:0] rs1, input integer imm);
        addi = {imm[11:0], rs1, 3'h0, rd, 7'h13};
    endfunction
    function [31:0] addiw(input [4:0] rd, input [4:0] rs1, input integer imm);
        addiw = {imm[11:0], rs1, 3'h0, rd, 7'h1b};
    endfunction
    function [31:0] op(input [4:0] rd, input [4:0] rs1, input [4:0] rs2,
                        input [2:0] funct3, input [6:0] funct7);
        op = {funct7, rs2, rs1, funct3, rd, 7'h33};
    endfunction
    function [31:0] load(input [4:0] rd, input [4:0] rs1, input integer imm);
        load = {imm[11:0], rs1, 3'h3, rd, 7'h03};
    endfunction
    function [31:0] store(input [4:0] rs2, input [4:0] rs1, input integer imm);
        store = {imm[11:5], rs2, rs1, 3'h3, imm[4:0], 7'h23};
    endfunction
    function [31:0] beq(input [4:0] rs1, input [4:0] rs2, input integer imm);
        beq = {imm[12], imm[10:5], rs2, rs1, 3'h0, imm[4:1], imm[11], 7'h63};
    endfunction

    task check_register(input [4:0] number, input [63:0] expected);
        begin
            debug_address = number; #1;
            if (debug_data !== expected)
                $fatal(1, "x%0d expected %h, got %h", number, expected, debug_data);
        end
    endtask

    initial begin
        for (index = 0; index < 32; index = index + 1) begin
            instructions[index] = 32'h00000013;
            memory[index] = 64'h0;
        end
        memory[1] = 64'hfeedfacecafebeef;
        instructions[0] = addi(1, 0, 5);
        instructions[1] = addi(2, 1, 7);                    // EX forwarding
        instructions[2] = store(2, 0, 0);
        instructions[3] = load(3, 0, 0);
        instructions[4] = op(4, 3, 2, 0, 0);              // load-use stall
        instructions[5] = addi(5, 0, 24);
        instructions[6] = beq(4, 5, 8);                   // taken, flush next store
        instructions[7] = store(1, 0, 8);
        instructions[8] = op(6, 1, 2, 0, 7'h01);          // MUL
        instructions[9] = addiw(7, 6, -61);
        instructions[10] = addi(8, 0, 9);
        instructions[11] = addi(0, 0, 0);
        instructions[12] = addi(0, 0, 0);
        instructions[13] = addi(9, 8, 1);                 // WB-to-ID register bypass
        instructions[14] = 32'h00100073;                  // EBREAK stops precisely
        instructions[15] = store(1, 0, 8);
        repeat (3) @(posedge clk); reset <= 0;
        repeat (200) begin
            @(posedge clk);
            if (halted) begin
                if (trap) $fatal(1, "unexpected trap cause=%0d pc=%h", trap_cause, trap_pc);
                check_register(1, 5);
                check_register(2, 12);
                check_register(3, 12);
                check_register(4, 24);
                check_register(6, 60);
                check_register(7, ~64'b0);
                check_register(9, 10);
                if (memory[0] !== 12) $fatal(1, "store/load memory mismatch: %h", memory[0]);
                if (memory[1] !== 64'hfeedfacecafebeef) $fatal(1, "flushed store committed");
                if (retired !== 14) $fatal(1, "expected 14 retired instructions, got %0d", retired);
                $display("PASS: five-stage pipeline, forwarding, WB bypass, load stall, memory wait, branch flush, RV64M");
                $finish;
            end
        end
        $fatal(1, "core timeout");
    end
endmodule
