`timescale 1ns/1ps
// Tang Primer 20K board wrapper for the Setsuna RTL.
// A small ROM program rotates the six active-low Dock LEDs through GPIO MMIO.
module tang_primer_20k_soc #(
    parameter [31:0] DELAY_INSTRUCTION = 32'h004001b7,
    parameter integer RESET_CYCLES = 16
) (
    input  wire       clk,
    output wire [5:0] led_n
);
    localparam integer RESET_WIDTH = (RESET_CYCLES > 1) ? $clog2(RESET_CYCLES + 1) : 1;
    reg [RESET_WIDTH-1:0] reset_count = 0;
    wire reset = reset_count < RESET_CYCLES;

    wire instruction_memory_valid;
    wire [63:0] instruction_memory_address;
    wire instruction_memory_ready = instruction_memory_valid;
    wire [63:0] instruction_memory_read_data;
    wire data_memory_valid;
    wire data_memory_write;
    wire [7:0] data_memory_write_strobe;
    wire [63:0] data_memory_address;
    wire [63:0] data_memory_write_data;
    wire data_memory_ready = data_memory_valid;
    wire [63:0] data_memory_read_data = 64'b0;
    wire [7:0] gpio_value;
    wire uart_tx_unused;
    wire [63:0] debug_data_unused;
    wire [63:0] cycle_count_unused;
    wire [63:0] retired_count_unused;
    wire halted_unused;
    wire trap_unused;
    wire [63:0] trap_pc_unused;
    wire [63:0] trap_cause_unused;
    wire [4:0] rom_word_index = {instruction_memory_address[6:3], 1'b0};

    always @(posedge clk) begin
        if (reset)
            reset_count <= reset_count + 1'b1;
    end

    function [31:0] program_word(input [4:0] index);
        begin
            case (index)
                0:  program_word = 32'h00f00093; // addi x1,x0,15
                1:  program_word = 32'h01c09093; // slli x1,x1,28 -> GPIO MMIO
                2:  program_word = 32'h00100113; // addi x2,x0,1
                3:  program_word = 32'h0020b023; // loop: sd x2,0(x1)
                4:  program_word = DELAY_INSTRUCTION; // default: lui x3,0x400
                5:  program_word = 32'hfff18193; // delay: addi x3,x3,-1
                6:  program_word = 32'hfe019ee3; // bne x3,x0,delay
                7:  program_word = 32'h00111293; // slli x5,x2,1
                8:  program_word = 32'h00515313; // srli x6,x2,5
                9:  program_word = 32'h0062e133; // or x2,x5,x6
                10: program_word = 32'h03f17113; // andi x2,x2,63
                11: program_word = 32'hfe1ff06f; // jal x0,loop
                default: program_word = 32'h00000013;
            endcase
        end
    endfunction

    assign instruction_memory_read_data = {
        program_word(rom_word_index + 1'b1),
        program_word(rom_word_index)
    };
    assign led_n = ~gpio_value[5:0];

    setsuna #(
        .RESET_VECTOR(64'b0),
        .ENABLE_M(0),
        .CACHE_LINE_COUNT(2),
        .CACHE_INDEX_BITS(1),
        .GPIO_WIDTH(8),
        .CLOCK_HZ(27000000),
        .UART_BAUD(115200)
    ) soc (
        .clk(clk),
        .reset(reset),
        .instruction_memory_valid(instruction_memory_valid),
        .instruction_memory_address(instruction_memory_address),
        .instruction_memory_ready(instruction_memory_ready),
        .instruction_memory_read_data(instruction_memory_read_data),
        .data_memory_valid(data_memory_valid),
        .data_memory_write(data_memory_write),
        .data_memory_write_strobe(data_memory_write_strobe),
        .data_memory_address(data_memory_address),
        .data_memory_write_data(data_memory_write_data),
        .data_memory_ready(data_memory_ready),
        .data_memory_read_data(data_memory_read_data),
        .gpio_input(8'b0),
        .gpio_output(gpio_value),
        .uart_tx(uart_tx_unused),
        .debug_register_address(5'b0),
        .debug_register_data(debug_data_unused),
        .cycle_count(cycle_count_unused),
        .retired_count(retired_count_unused),
        .halted(halted_unused),
        .trap(trap_unused),
        .trap_pc(trap_pc_unused),
        .trap_cause(trap_cause_unused)
    );
endmodule
