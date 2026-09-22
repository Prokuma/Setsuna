`timescale 1ns/1ps
// Platform-independent memory path used between Setsuna and a DDR3 PHY.
// At reset it copies a ROM image into DRAM, then releases the instruction
// and data ports and arbitrates both caches onto one DDR3 command port.
module dram_memory_subsystem #(
    parameter [63:0] DRAM_BASE = 64'h0000000080000000,
    parameter integer IMAGE_WORDS = 1,
    parameter IMAGE_FILE = "",
    parameter integer REFRESH_CYCLES = 778
) (
    input  wire        clk,
    input  wire        reset,
    output wire        boot_complete,

    input  wire        instruction_valid,
    input  wire [63:0] instruction_address,
    output wire        instruction_ready,
    output wire [63:0] instruction_read_data,
    input  wire        data_valid,
    input  wire        data_write,
    input  wire [7:0]  data_write_strobe,
    input  wire [63:0] data_address,
    input  wire [63:0] data_write_data,
    output wire        data_ready,
    output wire [63:0] data_read_data,

    input  wire        controller_init_done,
    output wire        controller_read,
    output wire        controller_write,
    output wire        controller_refresh,
    output wire [25:0] controller_address,
    output wire [15:0] controller_write_data,
    input  wire [15:0] controller_read_data,
    input  wire        controller_data_ready,
    input  wire        controller_busy
);
    wire boot_valid;
    wire boot_ready;
    wire [63:0] boot_address;
    wire [63:0] boot_write_data;
    wire boot_done;
    wire runtime_valid;
    wire runtime_write;
    wire [7:0] runtime_write_strobe;
    wire [63:0] runtime_address;
    wire [63:0] runtime_write_data;
    wire runtime_ready;
    wire [63:0] runtime_read_data;
    wire selected_valid = boot_done ? runtime_valid : boot_valid;
    wire selected_write = boot_done ? runtime_write : 1'b1;
    wire [7:0] selected_write_strobe = boot_done ? runtime_write_strobe : 8'hff;
    wire [63:0] selected_address = boot_done ? runtime_address : boot_address;
    wire [63:0] selected_write_data = boot_done ? runtime_write_data : boot_write_data;
    wire selected_ready;
    wire [63:0] selected_read_data;

    assign boot_complete = boot_done;
    assign boot_ready = !boot_done && selected_ready;
    assign runtime_ready = boot_done && selected_ready;
    assign runtime_read_data = selected_read_data;

    dram_boot_loader #(
        .DRAM_BASE(DRAM_BASE), .IMAGE_WORDS(IMAGE_WORDS), .IMAGE_FILE(IMAGE_FILE)
    ) loader (
        .clk(clk), .reset(reset), .memory_valid(boot_valid), .memory_write(),
        .memory_write_strobe(), .memory_address(boot_address),
        .memory_write_data(boot_write_data), .memory_ready(boot_ready), .done(boot_done)
    );

    memory_arbiter arbiter (
        .clk(clk), .reset(reset || !boot_done),
        .instruction_valid(instruction_valid), .instruction_address(instruction_address),
        .instruction_ready(instruction_ready),
        .instruction_read_data(instruction_read_data),
        .data_valid(data_valid), .data_write(data_write),
        .data_write_strobe(data_write_strobe), .data_address(data_address),
        .data_write_data(data_write_data), .data_ready(data_ready),
        .data_read_data(data_read_data), .memory_valid(runtime_valid),
        .memory_write(runtime_write), .memory_write_strobe(runtime_write_strobe),
        .memory_address(runtime_address), .memory_write_data(runtime_write_data),
        .memory_ready(runtime_ready), .memory_read_data(runtime_read_data)
    );

    ddr3_bus_adapter #(.DRAM_BASE(DRAM_BASE), .REFRESH_CYCLES(REFRESH_CYCLES)) adapter (
        .clk(clk), .reset(reset), .controller_init_done(controller_init_done),
        .request_valid(selected_valid), .request_write(selected_write),
        .request_write_strobe(selected_write_strobe), .request_address(selected_address),
        .request_write_data(selected_write_data), .request_ready(selected_ready),
        .request_read_data(selected_read_data), .controller_read(controller_read),
        .controller_write(controller_write), .controller_refresh(controller_refresh),
        .controller_address(controller_address),
        .controller_write_data(controller_write_data),
        .controller_read_data(controller_read_data),
        .controller_data_ready(controller_data_ready), .controller_busy(controller_busy)
    );
endmodule
