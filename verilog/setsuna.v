`timescale 1ns/1ps
module setsuna #(
    parameter [63:0] RESET_VECTOR = 64'h0000000080000000,
    parameter integer ENABLE_M = 1,
    parameter integer CACHE_LINE_COUNT = 16,
    parameter integer CACHE_INDEX_BITS = 4,
    parameter integer GPIO_WIDTH = 8,
    parameter integer CLOCK_HZ = 27000000,
    parameter integer UART_BAUD = 115200
) (
    input wire clk, input wire reset,
    output wire instruction_memory_valid,
    output wire [63:0] instruction_memory_address,
    input wire instruction_memory_ready,
    input wire [63:0] instruction_memory_read_data,
    output wire data_memory_valid, output wire data_memory_write,
    output wire [7:0] data_memory_write_strobe,
    output wire [63:0] data_memory_address, output wire [63:0] data_memory_write_data,
    input wire data_memory_ready, input wire [63:0] data_memory_read_data,
    input wire [GPIO_WIDTH-1:0] gpio_input,
    output wire [GPIO_WIDTH-1:0] gpio_output, output wire uart_tx,
    input wire [4:0] debug_register_address,
    output wire [63:0] debug_register_data,
    output wire [63:0] cycle_count, output wire [63:0] retired_count,
    output wire halted, output wire trap,
    output wire [63:0] trap_pc, output wire [63:0] trap_cause
);
    wire core_instruction_valid, core_instruction_ready;
    wire [63:0] core_instruction_address, instruction_cache_data;
    wire [31:0] core_instruction_data = core_instruction_address[2] ?
                                         instruction_cache_data[63:32] : instruction_cache_data[31:0];
    wire core_data_valid, core_data_write, core_data_ready;
    wire [7:0] core_data_write_strobe;
    wire [63:0] core_data_address, core_data_write_data, core_data_read_data;
    wire cached_data_valid, cached_data_write, cached_data_ready;
    wire [7:0] cached_data_write_strobe;
    wire [63:0] cached_data_address, cached_data_write_data, cached_data_read_data;

    core #(.RESET_VECTOR(RESET_VECTOR), .ENABLE_M(ENABLE_M)) processor (
        .clk(clk), .reset(reset),
        .instruction_valid(core_instruction_valid), .instruction_address(core_instruction_address),
        .instruction_ready(core_instruction_ready), .instruction_data(core_instruction_data),
        .data_valid(core_data_valid), .data_write(core_data_write),
        .data_write_strobe(core_data_write_strobe), .data_address(core_data_address),
        .data_write_data(core_data_write_data), .data_ready(core_data_ready),
        .data_read_data(core_data_read_data), .debug_register_address(debug_register_address),
        .debug_register_data(debug_register_data), .cycle_count(cycle_count),
        .retired_count(retired_count), .halted(halted), .trap(trap),
        .trap_pc(trap_pc), .trap_cause(trap_cause)
    );

    cache #(
        .LINE_COUNT(CACHE_LINE_COUNT),
        .INDEX_BITS(CACHE_INDEX_BITS)
    ) instruction_cache (
        .clk(clk), .reset(reset), .request_valid(core_instruction_valid),
        .request_write(1'b0), .request_write_strobe(8'b0),
        .request_address(core_instruction_address), .request_write_data(64'b0),
        .request_ready(core_instruction_ready), .request_read_data(instruction_cache_data),
        .memory_valid(instruction_memory_valid), .memory_write(), .memory_write_strobe(),
        .memory_address(instruction_memory_address), .memory_write_data(),
        .memory_ready(instruction_memory_ready), .memory_read_data(instruction_memory_read_data)
    );

    cache #(
        .LINE_COUNT(CACHE_LINE_COUNT),
        .INDEX_BITS(CACHE_INDEX_BITS)
    ) data_cache (
        .clk(clk), .reset(reset), .request_valid(core_data_valid),
        .request_write(core_data_write), .request_write_strobe(core_data_write_strobe),
        .request_address(core_data_address), .request_write_data(core_data_write_data),
        .request_ready(core_data_ready), .request_read_data(core_data_read_data),
        .memory_valid(cached_data_valid), .memory_write(cached_data_write),
        .memory_write_strobe(cached_data_write_strobe), .memory_address(cached_data_address),
        .memory_write_data(cached_data_write_data), .memory_ready(cached_data_ready),
        .memory_read_data(cached_data_read_data)
    );

    peripheral_bus #(.GPIO_WIDTH(GPIO_WIDTH), .CLOCK_HZ(CLOCK_HZ), .UART_BAUD(UART_BAUD)) peripherals (
        .clk(clk), .reset(reset), .request_valid(cached_data_valid),
        .request_write(cached_data_write), .request_write_strobe(cached_data_write_strobe),
        .request_address(cached_data_address), .request_write_data(cached_data_write_data),
        .request_ready(cached_data_ready), .request_read_data(cached_data_read_data),
        .memory_valid(data_memory_valid), .memory_write(data_memory_write),
        .memory_write_strobe(data_memory_write_strobe), .memory_address(data_memory_address),
        .memory_write_data(data_memory_write_data), .memory_ready(data_memory_ready),
        .memory_read_data(data_memory_read_data), .gpio_input(gpio_input),
        .gpio_output(gpio_output), .uart_tx_pin(uart_tx)
    );
endmodule
