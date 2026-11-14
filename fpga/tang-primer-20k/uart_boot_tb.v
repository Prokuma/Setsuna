`timescale 1ns/1ps
module uart_boot_tb;
    parameter EXPECTED = "Setsuna ready";
    localparam MESSAGE = {EXPECTED, 8'h0d, 8'h0a};
    localparam BAUD_CYCLES = 27000000 / 115200;
    reg clk = 0;
    always #18.519 clk = ~clk;
    tang_primer_20k_soc #(.SIMULATION(1), .CACHE_LINES(32), .CACHE_INDEX_BITS(5)) dut (.clk(clk));
    wire tx = dut.uart_tx_unused;
    reg [7:0] data;
    integer i, bit_index;
    initial begin
        wait (dut.boot_complete);
        for (i = $bits(MESSAGE)/8 - 1; i >= 0; i = i - 1) begin
            @(negedge tx);
            repeat (BAUD_CYCLES + BAUD_CYCLES/2) @(posedge clk);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                data[bit_index] = tx;
                repeat (BAUD_CYCLES) @(posedge clk);
            end
            if (data !== MESSAGE[8*i+:8] || tx !== 1'b1)
                $fatal(1, "UART byte %0d: got %h, expected %h", i, data, MESSAGE[8*i+:8]);
        end
        $display("PASS: DDR-model boot UART: %s", EXPECTED);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1, "DDR-model UART timeout");
    end
endmodule
