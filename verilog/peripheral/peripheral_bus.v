`timescale 1ns/1ps
module peripheral_bus #(
    parameter integer GPIO_WIDTH = 8,
    parameter integer CLOCK_HZ = 27000000,
    parameter integer UART_BAUD = 115200,
    parameter [63:0] MMIO_BASE = 64'h00000000f0000000
) (
    input  wire                  clk,
    input  wire                  reset,
    input  wire                  request_valid,
    input  wire                  request_write,
    input  wire [7:0]            request_write_strobe,
    input  wire [63:0]           request_address,
    input  wire [63:0]           request_write_data,
    output reg                   request_ready,
    output reg  [63:0]           request_read_data,
    output wire                  memory_valid,
    output wire                  memory_write,
    output wire [7:0]            memory_write_strobe,
    output wire [63:0]           memory_address,
    output wire [63:0]           memory_write_data,
    input  wire                  memory_ready,
    input  wire [63:0]           memory_read_data,
    input  wire [GPIO_WIDTH-1:0] gpio_input,
    output wire [GPIO_WIDTH-1:0] gpio_output,
    output wire                  uart_tx_pin
);
    wire mmio = request_address[63:12] == MMIO_BASE[63:12];
    wire gpio_select = mmio && request_address[11:3] == 0;
    wire uart_data_select = mmio && request_address[11:3] == 2;
    wire uart_status_select = mmio && request_address[11:3] == 3;
    wire [63:0] gpio_read_data;
    wire uart_busy;

    gpio #(.WIDTH(GPIO_WIDTH)) gpio_device (
        .clk(clk), .reset(reset),
        .write_enable(request_valid && request_write && gpio_select),
        .write_strobe(request_write_strobe), .write_data(request_write_data),
        .input_pins(gpio_input), .output_pins(gpio_output), .read_data(gpio_read_data)
    );
    uart_tx #(.CLOCK_HZ(CLOCK_HZ), .BAUD(UART_BAUD)) uart_device (
        .clk(clk), .reset(reset),
        .write_enable(request_valid && request_write && uart_data_select && !uart_busy),
        .write_data(request_write_data[7:0]), .tx(uart_tx_pin), .busy(uart_busy)
    );

    assign memory_valid = request_valid && !mmio;
    assign memory_write = request_write;
    assign memory_write_strobe = request_write_strobe;
    assign memory_address = request_address;
    assign memory_write_data = request_write_data;

    always @* begin
        if (!mmio) begin
            request_ready = memory_ready;
            request_read_data = memory_read_data;
        end else begin
            request_ready = request_valid;
            request_read_data = 64'b0;
            if (gpio_select) request_read_data = gpio_read_data;
            if (uart_status_select) request_read_data = {63'b0, uart_busy};
            if (uart_data_select && request_write && uart_busy) request_ready = 1'b0;
        end
    end
endmodule
