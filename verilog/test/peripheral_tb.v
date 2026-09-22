`timescale 1ns/1ps
module peripheral_tb;
    reg clk = 0, reset = 1, valid = 0, write_enable = 0;
    reg [7:0] strobe = 0;
    reg [63:0] address = 0, write_data = 0;
    wire ready;
    wire [63:0] read_data;
    wire memory_valid, memory_write, uart_tx;
    wire [7:0] memory_strobe, gpio_output;
    wire [63:0] memory_address, memory_write_data;
    reg memory_ready = 0;
    reg [63:0] memory_read_data = 64'h1234;
    reg [7:0] gpio_input = 8'h5a;
    integer low_ticks = 0;
    peripheral_bus #(.GPIO_WIDTH(8), .CLOCK_HZ(12), .UART_BAUD(3)) dut (
        .clk(clk), .reset(reset), .request_valid(valid), .request_write(write_enable),
        .request_write_strobe(strobe), .request_address(address), .request_write_data(write_data),
        .request_ready(ready), .request_read_data(read_data), .memory_valid(memory_valid),
        .memory_write(memory_write), .memory_write_strobe(memory_strobe),
        .memory_address(memory_address), .memory_write_data(memory_write_data),
        .memory_ready(memory_ready), .memory_read_data(memory_read_data),
        .gpio_input(gpio_input), .gpio_output(gpio_output), .uart_tx_pin(uart_tx)
    );
    always #5 clk = ~clk;
    always @(posedge clk) if (!uart_tx) low_ticks <= low_ticks + 1;
    initial begin
        repeat (3) @(posedge clk); reset <= 0;
        @(negedge clk); valid=1; write_enable=1; strobe=8'h01;
        address=64'hf0000000; write_data=64'ha5;
        @(posedge clk); #1;
        if (!ready || gpio_output !== 8'ha5) $fatal(1, "GPIO write failed");
        @(negedge clk); write_enable=0;
        #1; if (!ready || read_data !== 64'h5a) $fatal(1, "GPIO read failed");
        @(negedge clk); write_enable=1; address=64'hf0000010; write_data=8'h41;
        @(posedge clk); @(negedge clk); write_enable=0; address=64'hf0000018;
        #1; if (!read_data[0]) $fatal(1, "UART did not become busy");
        repeat (45) @(posedge clk);
        if (low_ticks == 0 || uart_tx !== 1) $fatal(1, "UART waveform failed");
        @(negedge clk); address=64'h1000; memory_ready=1;
        #1; if (!memory_valid || ready !== 1 || read_data !== 64'h1234)
            $fatal(1, "external memory forwarding failed");
        $display("PASS: GPIO MMIO, UART TX/status, external memory forwarding");
        $finish;
    end
endmodule
