`timescale 1ns/1ps
`ifndef SETSUNA_BOOT_IMAGE
`define SETSUNA_BOOT_IMAGE "fpga/tang-primer-20k/demo_program.hex"
`endif
`ifndef SETSUNA_BOOT_WORDS
`define SETSUNA_BOOT_WORDS 6
`endif

// Tang Primer 20K board wrapper. A block-ROM image is copied into the onboard
// 128 MB DDR3, then Setsuna starts executing at 0x8000_0000 through its caches.
module tang_primer_20k_soc #(
    parameter integer SIMULATION = 0,
    parameter BOOT_IMAGE_FILE = `SETSUNA_BOOT_IMAGE,
    parameter integer BOOT_IMAGE_WORDS = `SETSUNA_BOOT_WORDS,
    parameter integer RESET_CYCLES = 16
) (
    input  wire        clk,
    output wire [5:0]  led_n,
    inout  wire [15:0] ddr_dq,
    inout  wire [1:0]  ddr_dqs,
    output wire [12:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs_n,
    output wire        ddr_ras_n,
    output wire        ddr_cas_n,
    output wire        ddr_we_n,
    output wire        ddr_ck,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [1:0]  ddr_dm
);
    localparam [63:0] DRAM_BASE = 64'h0000000080000000;
    localparam integer RESET_WIDTH = RESET_CYCLES > 1 ? $clog2(RESET_CYCLES + 1) : 1;
    reg [RESET_WIDTH-1:0] reset_count = 0;
    wire power_reset = reset_count < RESET_CYCLES;
    wire system_clk;
    wire ddr_init_done;
    wire boot_complete;
    wire processor_reset = !boot_complete;

    wire instruction_memory_valid;
    wire [63:0] instruction_memory_address;
    wire instruction_memory_ready;
    wire [63:0] instruction_memory_read_data;
    wire data_memory_valid;
    wire data_memory_write;
    wire [7:0] data_memory_write_strobe;
    wire [63:0] data_memory_address;
    wire [63:0] data_memory_write_data;
    wire data_memory_ready;
    wire [63:0] data_memory_read_data;
    wire controller_read;
    wire controller_write;
    wire controller_refresh;
    wire [25:0] controller_address;
    wire [15:0] controller_write_data;
    wire [15:0] controller_read_data;
    wire controller_data_ready;
    wire controller_busy;
    wire [7:0] gpio_value;
    wire uart_tx_unused;
    wire [63:0] debug_data_unused;
    wire [63:0] cycle_count_unused;
    wire [63:0] retired_count_unused;
    wire halted_unused;
    wire trap_unused;
    wire [63:0] trap_pc_unused;
    wire [63:0] trap_cause_unused;

    always @(posedge clk) begin
        if (power_reset)
            reset_count <= reset_count + 1'b1;
    end

    tang_primer_20k_ddr3 #(.SIMULATION(SIMULATION)) physical_memory (
        .clk27(clk), .reset(power_reset), .system_clk(system_clk),
        .init_done(ddr_init_done), .read_command(controller_read),
        .write_command(controller_write), .refresh_command(controller_refresh),
        .address(controller_address), .write_data(controller_write_data),
        .read_data(controller_read_data), .data_ready(controller_data_ready),
        .busy(controller_busy), .ddr_dq(ddr_dq), .ddr_dqs(ddr_dqs),
        .ddr_addr(ddr_addr), .ddr_bank(ddr_bank), .ddr_cs_n(ddr_cs_n),
        .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n),
        .ddr_ck(ddr_ck), .ddr_cke(ddr_cke), .ddr_odt(ddr_odt),
        .ddr_reset_n(ddr_reset_n), .ddr_dm(ddr_dm)
    );

    dram_memory_subsystem #(
        .DRAM_BASE(DRAM_BASE), .IMAGE_WORDS(BOOT_IMAGE_WORDS),
        .IMAGE_FILE(BOOT_IMAGE_FILE), .REFRESH_CYCLES(778)
    ) memory (
        .clk(system_clk), .reset(power_reset), .boot_complete(boot_complete),
        .instruction_valid(instruction_memory_valid),
        .instruction_address(instruction_memory_address),
        .instruction_ready(instruction_memory_ready),
        .instruction_read_data(instruction_memory_read_data),
        .data_valid(data_memory_valid), .data_write(data_memory_write),
        .data_write_strobe(data_memory_write_strobe), .data_address(data_memory_address),
        .data_write_data(data_memory_write_data), .data_ready(data_memory_ready),
        .data_read_data(data_memory_read_data), .controller_init_done(ddr_init_done),
        .controller_read(controller_read), .controller_write(controller_write),
        .controller_refresh(controller_refresh), .controller_address(controller_address),
        .controller_write_data(controller_write_data),
        .controller_read_data(controller_read_data),
        .controller_data_ready(controller_data_ready), .controller_busy(controller_busy)
    );

    setsuna #(
        .RESET_VECTOR(DRAM_BASE), .ENABLE_M(0),
        .CACHE_LINE_COUNT(2), .CACHE_INDEX_BITS(1), .GPIO_WIDTH(8),
        .CLOCK_HZ(99562500), .UART_BAUD(115200)
    ) soc (
        .clk(system_clk), .reset(processor_reset),
        .instruction_memory_valid(instruction_memory_valid),
        .instruction_memory_address(instruction_memory_address),
        .instruction_memory_ready(instruction_memory_ready),
        .instruction_memory_read_data(instruction_memory_read_data),
        .data_memory_valid(data_memory_valid), .data_memory_write(data_memory_write),
        .data_memory_write_strobe(data_memory_write_strobe),
        .data_memory_address(data_memory_address),
        .data_memory_write_data(data_memory_write_data),
        .data_memory_ready(data_memory_ready), .data_memory_read_data(data_memory_read_data),
        .gpio_input(8'b0), .gpio_output(gpio_value), .uart_tx(uart_tx_unused),
        .debug_register_address(5'b0), .debug_register_data(debug_data_unused),
        .cycle_count(cycle_count_unused), .retired_count(retired_count_unused),
        .halted(halted_unused), .trap(trap_unused), .trap_pc(trap_pc_unused),
        .trap_cause(trap_cause_unused)
    );

    assign led_n = ~gpio_value[5:0];
endmodule
