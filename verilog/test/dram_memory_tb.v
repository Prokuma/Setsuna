`timescale 1ns/1ps
module dram_memory_tb;
    localparam [63:0] DRAM_BASE = 64'h0000000080000000;
    reg clk = 0;
    reg reset = 1;
    always #5 clk = ~clk;

    reg instruction_valid = 0;
    reg [63:0] instruction_address = 0;
    wire instruction_ready;
    wire [63:0] instruction_read_data;
    reg data_valid = 0;
    reg data_write = 0;
    reg [7:0] data_write_strobe = 0;
    reg [63:0] data_address = 0;
    reg [63:0] data_write_data = 0;
    wire data_ready;
    wire [63:0] data_read_data;
    wire boot_complete;

    reg controller_init_done = 0;
    wire controller_read;
    wire controller_write;
    wire controller_refresh;
    wire [25:0] controller_address;
    wire [15:0] controller_write_data;
    reg [15:0] controller_read_data = 0;
    reg controller_data_ready = 0;
    reg controller_busy = 1;
    reg [15:0] memory [0:255];
    reg [25:0] captured_address;
    reg [2:0] backend_count;
    reg backend_read;
    reg backend_write;
    integer refresh_count = 0;
    integer i;

    dram_memory_subsystem #(
        .DRAM_BASE(DRAM_BASE), .IMAGE_WORDS(3),
        .IMAGE_FILE("verilog/test/dram_boot.hex"), .REFRESH_CYCLES(32)
    ) dut (
        .clk(clk), .reset(reset), .boot_complete(boot_complete),
        .instruction_valid(instruction_valid), .instruction_address(instruction_address),
        .instruction_ready(instruction_ready),
        .instruction_read_data(instruction_read_data),
        .data_valid(data_valid), .data_write(data_write),
        .data_write_strobe(data_write_strobe), .data_address(data_address),
        .data_write_data(data_write_data), .data_ready(data_ready),
        .data_read_data(data_read_data), .controller_init_done(controller_init_done),
        .controller_read(controller_read), .controller_write(controller_write),
        .controller_refresh(controller_refresh), .controller_address(controller_address),
        .controller_write_data(controller_write_data),
        .controller_read_data(controller_read_data),
        .controller_data_ready(controller_data_ready), .controller_busy(controller_busy)
    );

    // Small timing model for the single-word DDR3 controller interface.
    always @(posedge clk) begin
        controller_data_ready <= 1'b0;
        if (reset) begin
            controller_busy <= 1'b1;
            backend_count <= 0;
            backend_read <= 1'b0;
            backend_write <= 1'b0;
            refresh_count <= 0;
        end else if (!controller_init_done) begin
            controller_busy <= 1'b1;
        end else if (!controller_busy) begin
            if (controller_read || controller_write || controller_refresh) begin
                controller_busy <= 1'b1;
                backend_count <= 3;
                captured_address <= controller_address;
                backend_read <= controller_read;
                backend_write <= controller_write;
                if (controller_write)
                    memory[controller_address] <= controller_write_data;
                if (controller_refresh)
                    refresh_count <= refresh_count + 1;
            end
        end else if (backend_count != 0) begin
            backend_count <= backend_count - 1'b1;
            if (backend_count == 1) begin
                controller_busy <= 1'b0;
                if (backend_read) begin
                    controller_read_data <= memory[captured_address];
                    controller_data_ready <= 1'b1;
                end
                backend_read <= 1'b0;
                backend_write <= 1'b0;
            end
        end
    end

    task read_instruction(input [63:0] address, input [63:0] expected);
        begin
            @(negedge clk);
            instruction_address = address;
            instruction_valid = 1'b1;
            while (!instruction_ready) @(negedge clk);
            if (instruction_read_data !== expected) begin
                $display("FAIL: instruction read %h, expected %h", instruction_read_data, expected);
                $fatal(1);
            end
            instruction_valid = 1'b0;
        end
    endtask

    task write_data(input [63:0] address, input [63:0] value, input [7:0] strobe);
        begin
            @(negedge clk);
            data_address = address;
            data_write_data = value;
            data_write_strobe = strobe;
            data_write = 1'b1;
            data_valid = 1'b1;
            while (!data_ready) @(negedge clk);
            data_valid = 1'b0;
            data_write = 1'b0;
        end
    endtask

    task read_data(input [63:0] address, input [63:0] expected);
        begin
            @(negedge clk);
            data_address = address;
            data_write = 1'b0;
            data_valid = 1'b1;
            while (!data_ready) @(negedge clk);
            if (data_read_data !== expected) begin
                $display("FAIL: data read %h, expected %h", data_read_data, expected);
                $fatal(1);
            end
            data_valid = 1'b0;
        end
    endtask

    initial begin
        for (i = 0; i < 256; i = i + 1)
            memory[i] = 0;
        repeat (4) @(posedge clk);
        reset = 0;
        repeat (3) @(posedge clk);
        controller_init_done = 1;
        controller_busy = 0;

        wait (boot_complete);
        if ({memory[3], memory[2], memory[1], memory[0]} !== 64'h0123456789abcdef ||
            {memory[7], memory[6], memory[5], memory[4]} !== 64'hfedcba9876543210 ||
            {memory[11], memory[10], memory[9], memory[8]} !== 64'h55aa00ff11223344) begin
            $display("FAIL: boot copy %h %h %h",
                     {memory[3], memory[2], memory[1], memory[0]},
                     {memory[7], memory[6], memory[5], memory[4]},
                     {memory[11], memory[10], memory[9], memory[8]});
            $fatal(1);
        end
        read_instruction(DRAM_BASE, 64'h0123456789abcdef);
        read_data(DRAM_BASE + 8, 64'hfedcba9876543210);

        write_data(DRAM_BASE + 8, 64'h8877665544332211, 8'hff);
        read_data(DRAM_BASE + 8, 64'h8877665544332211);

        write_data(DRAM_BASE + 16, 64'h00000000000000ee, 8'h01);
        read_data(DRAM_BASE + 16, 64'h55aa00ff112233ee);

        repeat (80) @(posedge clk);
        if (refresh_count == 0) begin
            $display("FAIL: no DDR refresh command was issued");
            $fatal(1);
        end
        $display("PASS: boot image copied to DRAM and cached memory port transactions completed");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout");
        $fatal(1);
    end
endmodule
