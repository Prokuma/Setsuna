`timescale 1ns/1ps
module dram_boot_case #(parameter integer CASE = 0, parameter integer WORDS = 3) (
    input wire clk, input wire reset, output reg finished = 0
);
    wire valid, write, done, verifying, failed;
    wire [7:0] strobe;
    wire [63:0] address, data;
    wire [1:0] error_code;
    reg ready = 0;
    reg [63:0] read_data = 0;
    reg [63:0] memory [0:WORDS-1];
    integer i, writes = 0, reads = 0, delay_count = 0;
    wire [63:0] index = (address - 64'h80000000) >> 3;
    dram_boot_loader #(.IMAGE_WORDS(WORDS), .TIMEOUT_CYCLES(32)) dut (
        .clk(clk), .reset(reset), .memory_valid(valid), .memory_write(write),
        .memory_write_strobe(strobe), .memory_address(address), .memory_write_data(data),
        .memory_ready(ready), .memory_read_data(read_data), .done(done),
        .verifying(verifying), .failed(failed), .error_code(error_code)
    );
    initial for (i = 0; i < WORDS; i = i + 1) begin
        dut.image[i] = 64'h0123456789abcdef ^ i;
        memory[i] = 0;
    end
    always @(posedge clk) begin
        ready <= 0;
        if (reset) begin writes <= 0; reads <= 0; delay_count <= 0; finished <= 0; end
        else if (valid && !ready && CASE != 2 && !(CASE == 3 && !write)) begin
            if (delay_count == 2) begin
                ready <= 1;
                delay_count <= 0;
                if (index >= WORDS) $fatal(1, "boot address outside image");
                if (write) begin
                    if (strobe != 8'hff) $fatal(1, "boot write strobe changed");
                    memory[index] <= data;
                    writes <= writes + 1;
                end else begin
                    read_data <= memory[index] ^ ((CASE == 1 && index == 1) ? 64'd1 : 64'd0);
                    reads <= reads + 1;
                end
            end else delay_count <= delay_count + 1;
        end
        if (!reset && (done || failed) && !finished) begin
            if (CASE == 0 || CASE == 4) begin
                if (!done || failed || !verifying || writes != WORDS || reads != WORDS)
                    $fatal(1, "boot was not fully verified, case %0d", CASE);
            end else begin
                if (done || !failed || error_code != CASE || valid)
                    $fatal(1, "incorrect boot failure case=%0d code=%0d", CASE, error_code);
            end
            finished <= 1;
        end
        if (!reset && finished && valid) $fatal(1, "boot resumed after completion/failure");
    end
endmodule

module dram_boot_tb;
    reg clk = 0, reset = 1;
    wire [4:0] finished;
    always #5 clk = ~clk;
    dram_boot_case #(.CASE(0)) success (.clk(clk), .reset(reset), .finished(finished[0]));
    dram_boot_case #(.CASE(1)) corrupt (.clk(clk), .reset(reset), .finished(finished[1]));
    dram_boot_case #(.CASE(2)) no_response (.clk(clk), .reset(reset), .finished(finished[2]));
    dram_boot_case #(.CASE(3)) read_timeout (.clk(clk), .reset(reset), .finished(finished[3]));
    dram_boot_case #(.CASE(4), .WORDS(1)) single (.clk(clk), .reset(reset), .finished(finished[4]));
    initial begin
        repeat (4) @(negedge clk); reset = 0;
        wait (&finished);
        repeat (4) @(negedge clk);
        $display("PASS: DDR boot readback, corruption rejection, write/read timeouts, single-word image");
        $finish;
    end
    initial begin #20000; $fatal(1, "DDR boot test timeout"); end
endmodule
