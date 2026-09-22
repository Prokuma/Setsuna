`timescale 1ns/1ps
module blink_tb;
    reg clk = 0;
    wire [5:0] led_n;
    reg [5:0] expected = 6'b000001;
    integer step, tick;
    blink #(.CLOCK_HZ(12)) dut (.clk(clk), .led_n(led_n));
    always #5 clk = ~clk;
    initial begin
        #1;
        if (led_n !== ~expected) $fatal(1, "incorrect startup LEDs");
        for (step = 0; step < 12; step = step + 1) begin
            for (tick = 0; tick < 6; tick = tick + 1) begin
                @(posedge clk); #1;
                if (tick == 5) expected = {expected[4:0], expected[5]};
                if (led_n !== ~expected) $fatal(1, "incorrect LED sequence/period");
            end
        end
        $display("PASS: startup, half-second divider, two complete LED rotations");
        $finish;
    end
    initial begin
        #10000; $fatal(1, "testbench timeout");
    end
endmodule
