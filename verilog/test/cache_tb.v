`timescale 1ns/1ps
module cache_tb;
    reg clk = 0, reset = 1;
    reg request_valid = 0, request_write = 0;
    reg [7:0] request_strobe = 0;
    reg [63:0] request_address = 0, request_write_data = 0;
    wire request_ready;
    wire [63:0] request_read_data;
    wire memory_valid, memory_write;
    wire [7:0] memory_strobe;
    wire [63:0] memory_address, memory_write_data;
    reg memory_ready = 0;
    reg [63:0] memory_read_data = 0;
    reg [63:0] memory [0:63];
    integer reads = 0, writes = 0, index, wait_cycles = 0;

    cache #(.LINE_COUNT(4), .INDEX_BITS(2)) dut (
        .clk(clk), .reset(reset), .request_valid(request_valid), .request_write(request_write),
        .request_write_strobe(request_strobe), .request_address(request_address),
        .request_write_data(request_write_data), .request_ready(request_ready),
        .request_read_data(request_read_data), .memory_valid(memory_valid),
        .memory_write(memory_write), .memory_write_strobe(memory_strobe),
        .memory_address(memory_address), .memory_write_data(memory_write_data),
        .memory_ready(memory_ready), .memory_read_data(memory_read_data)
    );
    always #5 clk = ~clk;
    always @(posedge clk) begin
        memory_ready <= 0;
        if (memory_valid) begin
            if (wait_cycles == 1) begin
                memory_ready <= 1;
                memory_read_data <= memory[memory_address[8:3]];
                if (memory_write) begin
                    writes <= writes + 1;
                    for (index = 0; index < 8; index = index + 1)
                        if (memory_strobe[index])
                            memory[memory_address[8:3]][index*8 +: 8] <= memory_write_data[index*8 +: 8];
                end else reads <= reads + 1;
                wait_cycles <= 0;
            end else wait_cycles <= wait_cycles + 1;
        end else wait_cycles <= 0;
    end

    task transact(input wr, input [63:0] address, input [63:0] data,
                  input [7:0] strobe, output [63:0] result);
        begin
            @(negedge clk);
            request_valid = 1; request_write = wr; request_address = address;
            request_write_data = data; request_strobe = strobe;
            while (!request_ready) @(negedge clk);
            result = request_read_data;
            request_valid = 0;
            @(negedge clk);
        end
    endtask
    reg [63:0] value;
    initial begin
        for (index = 0; index < 64; index = index + 1) memory[index] = 64'h1000 + index;
        repeat (3) @(posedge clk); reset <= 0;
        transact(0, 0, 0, 0, value);
        if (value !== 64'h1000 || reads !== 1) $fatal(1, "read miss failed");
        transact(0, 0, 0, 0, value);
        if (value !== 64'h1000 || reads !== 1) $fatal(1, "read hit accessed backing memory");
        transact(1, 0, 64'h00000000000000aa, 8'h01, value);
        transact(0, 0, 0, 0, value);
        if (value !== 64'h00000000000010aa) $fatal(1, "write hit failed: %h", value);
        transact(0, 32, 0, 0, value); // same index: dirty eviction
        if (memory[0] !== 64'h00000000000010aa || writes !== 1)
            $fatal(1, "dirty writeback failed");
        transact(1, 64'hf0000000, 64'h55, 8'hff, value);
        if (memory[0] !== 64'h55 || writes !== 2) $fatal(1, "uncached bypass failed");
        $display("PASS: cache miss, hit, byte write, dirty eviction, uncached bypass");
        $finish;
    end
endmodule
