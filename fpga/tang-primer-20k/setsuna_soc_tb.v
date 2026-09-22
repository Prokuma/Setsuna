`timescale 1ns/1ps
module tang_primer_20k_soc_tb;
    reg clk = 0;
    wire [5:0] led_n;

    tang_primer_20k_soc #(
        .SIMULATION(1),
        .BOOT_IMAGE_FILE("fpga/tang-primer-20k/demo_program_sim.hex"),
        .BOOT_IMAGE_WORDS(6),
        .RESET_CYCLES(4)
    ) dut (
        .clk(clk),
        .led_n(led_n)
    );

    always #5 clk = ~clk;
    initial begin
        wait (dut.boot_complete);
        wait (led_n === 6'b111110);
        wait (led_n === 6'b111101);
        wait (led_n === 6'b111100);
        if (dut.trap_unused) $fatal(1, "CPU trapped while executing from modeled DDR3");
        $display("PASS: DDR3 boot program increments the six-bit GPIO LED counter");
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $fatal(1, "Setsuna DDR3 boot timeout, led_n=%b pc=%h retired=%0d x2=%h x3=%h x5=%h x6=%h trap=%b halted=%b",
               led_n, dut.soc.processor.fetch_pc, dut.retired_count_unused,
               dut.soc.processor.registers.registers[2], dut.soc.processor.registers.registers[3],
               dut.soc.processor.registers.registers[5], dut.soc.processor.registers.registers[6],
               dut.trap_unused, dut.halted_unused);
    end
endmodule
