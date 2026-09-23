`timescale 1ns/1ps
module tang_primer_20k_soc_tb;
`ifndef SETSUNA_BOOT_FROM_DDR
`define SETSUNA_BOOT_FROM_DDR 1
`endif
    reg clk = 0;
    wire [5:0] led_n;

    tang_primer_20k_soc #(
        .SIMULATION(1), .LED_STATUS(0),
        .BOOT_FROM_DDR(`SETSUNA_BOOT_FROM_DDR),
        .BOOT_IMAGE_FILE("fpga/tang-primer-20k/demo_program_sim.hex"),
        .BOOT_IMAGE_WORDS(6),
        .RESET_CYCLES(4)
    ) dut (
        .clk(clk),
        .led_n(led_n)
    );

    wire [5:0] status_led_n;
    tang_primer_20k_soc #(
        .SIMULATION(1), .LED_STATUS(1), .HEARTBEAT_BITS(4),
        .BOOT_FROM_DDR(`SETSUNA_BOOT_FROM_DDR),
        .BOOT_IMAGE_FILE("fpga/tang-primer-20k/demo_program_sim.hex"),
        .BOOT_IMAGE_WORDS(6), .RESET_CYCLES(4)
    ) diagnostic (.clk(clk), .led_n(status_led_n));
    reg heartbeat_seen = 0;
    always @(posedge clk) if (!status_led_n[5]) heartbeat_seen <= 1;
    always #5 clk = ~clk;
    initial begin
        wait (dut.boot_complete);
        wait (led_n === 6'b111110);
        wait (led_n === 6'b111101);
        wait (led_n === 6'b111100);
        if (dut.trap_unused) $fatal(1, "CPU trapped during boot test");
        if (status_led_n[4:0] !== 5'b10000 || !heartbeat_seen)
            $fatal(1, "incorrect boot diagnostics: %b", status_led_n);
        $display("PASS: boot_from_ddr=%0d increments LED counter 1 -> 2 -> 3", `SETSUNA_BOOT_FROM_DDR);
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
