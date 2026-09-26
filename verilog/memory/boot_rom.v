`timescale 1ns/1ps
// Synchronous dual-read block ROM. Stores are acknowledged but ignored.
// Unmapped reads return zero; no RAM is provided by this diagnostic backend.
module boot_rom #(
    parameter IMAGE_FILE = "",
    parameter integer IMAGE_WORDS = 1,
    parameter [63:0] BASE = 64'h80000000
) (
    input wire clk, reset,
    input wire instruction_valid,
    input wire [63:0] instruction_address,
    output reg instruction_ready,
    output wire [63:0] instruction_read_data,
    input wire data_valid, data_write,
    input wire [63:0] data_address,
    output reg data_ready,
    output wire [63:0] data_read_data
);
    localparam integer BITS = IMAGE_WORDS <= 256 ? 8 : $clog2(IMAGE_WORDS);
    (* rom_style = "block" *) reg [63:0] image [0:(1<<BITS)-1];
    reg [63:0] instruction_word, data_word;
    reg instruction_mapped, data_mapped;
    integer i;
    initial begin
        // Do not overlap procedural zero-fill with $readmemh initialization:
        // Yosys can give the zero-fill priority over the file contents.
        for (i = IMAGE_WORDS; i < (1<<BITS); i = i + 1) image[i] = 0;
        if (IMAGE_FILE != "") $readmemh(IMAGE_FILE, image, 0, IMAGE_WORDS-1);
    end
    // Keep the memory read registers free of reset for block-memory inference.
    always @(posedge clk) begin
        instruction_word <= image[instruction_address[BITS+2:3]];
        data_word <= image[data_address[BITS+2:3]];
        instruction_mapped <= instruction_address >= BASE &&
                              instruction_address - BASE < IMAGE_WORDS * 8;
        data_mapped <= !data_write && data_address >= BASE &&
                       data_address - BASE < IMAGE_WORDS * 8;
        if (reset) begin
            instruction_ready <= 0;
            data_ready <= 0;
        end else begin
            instruction_ready <= instruction_valid && !instruction_ready;
            data_ready <= data_valid && !data_ready;
        end
    end
    assign instruction_read_data = instruction_mapped ? instruction_word : 64'b0;
    assign data_read_data = data_mapped ? data_word : 64'b0;
endmodule
