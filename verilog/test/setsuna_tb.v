`timescale 1ns/1ps
module setsuna_tb;
    reg clk = 0, reset = 1;
    wire imem_valid, dmem_valid, dmem_write;
    wire [7:0] dmem_strobe, gpio_output;
    wire [63:0] imem_address, dmem_address, dmem_write_data;
    reg imem_ready = 0, dmem_ready = 0;
    reg [63:0] imem_read_data = 0, dmem_read_data = 0;
    reg [63:0] instruction_memory [0:15];
    reg [63:0] data_memory [0:15];
    wire uart_tx, halted, trap;
    wire [63:0] debug_data, cycles, retired, trap_pc, trap_cause;
    integer index;

    setsuna #(.RESET_VECTOR(0), .GPIO_WIDTH(8), .CLOCK_HZ(12), .UART_BAUD(3)) dut (
        .clk(clk), .reset(reset),
        .instruction_memory_valid(imem_valid), .instruction_memory_address(imem_address),
        .instruction_memory_ready(imem_ready), .instruction_memory_read_data(imem_read_data),
        .data_memory_valid(dmem_valid), .data_memory_write(dmem_write),
        .data_memory_write_strobe(dmem_strobe), .data_memory_address(dmem_address),
        .data_memory_write_data(dmem_write_data), .data_memory_ready(dmem_ready),
        .data_memory_read_data(dmem_read_data), .gpio_input(8'h3c), .gpio_output(gpio_output),
        .uart_tx(uart_tx), .debug_register_address(5'd0), .debug_register_data(debug_data),
        .cycle_count(cycles), .retired_count(retired), .halted(halted), .trap(trap),
        .trap_pc(trap_pc), .trap_cause(trap_cause)
    );
    always #5 clk = ~clk;
    always @(posedge clk) begin
        imem_ready <= imem_valid;
        if (imem_valid) imem_read_data <= instruction_memory[imem_address[6:3]];
        dmem_ready <= dmem_valid;
        if (dmem_valid) begin
            dmem_read_data <= data_memory[dmem_address[6:3]];
            if (dmem_write)
                for (index = 0; index < 8; index = index + 1)
                    if (dmem_strobe[index])
                        data_memory[dmem_address[6:3]][index*8 +: 8] <=
                            dmem_write_data[index*8 +: 8];
        end
    end

    initial begin
        for (index = 0; index < 16; index = index + 1) begin
            instruction_memory[index] = 0;
            data_memory[index] = 0;
        end
        // addi x1,x0,15; slli x1,x1,28 => 0x00000000f0000000
        instruction_memory[0] = {32'h01c09093, 32'h00f00093};
        // addi x2,x0,0x2a; sd x2,0(x1)
        instruction_memory[1] = {32'h0020b023, 32'h02a00113};
        // ebreak; younger write must not execute
        instruction_memory[2] = {32'h0010b423, 32'h00100073};
        repeat (3) @(posedge clk); reset <= 0;
        repeat (300) begin
            @(posedge clk);
            if (halted) begin
                if (trap) $fatal(1, "unexpected SoC trap cause=%0d", trap_cause);
                if (gpio_output !== 8'h2a) $fatal(1, "MMIO write through data cache failed: %h", gpio_output);
                if (retired !== 5) $fatal(1, "expected 5 retired, got %0d", retired);
                $display("PASS: core + I/D caches + peripheral bus integration");
                $finish;
            end
        end
        $fatal(1, "integrated SoC timeout");
    end
endmodule
