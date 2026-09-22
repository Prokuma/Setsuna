`timescale 1ns/1ps
// Copies a build-time image from FPGA block ROM to external DRAM before the
// processor leaves reset. The image contains little-endian 64-bit words.
module dram_boot_loader #(
    parameter [63:0] DRAM_BASE = 64'h0000000080000000,
    parameter integer IMAGE_WORDS = 1,
    parameter IMAGE_FILE = ""
) (
    input  wire        clk,
    input  wire        reset,
    output wire        memory_valid,
    output wire        memory_write,
    output wire [7:0]  memory_write_strobe,
    output wire [63:0] memory_address,
    output wire [63:0] memory_write_data,
    input  wire        memory_ready,
    output reg         done
);
    localparam integer INDEX_BITS = IMAGE_WORDS <= 1 ? 1 : $clog2(IMAGE_WORDS);
    reg [63:0] image [0:IMAGE_WORDS-1];
    reg [INDEX_BITS-1:0] index;

    initial begin
        if (IMAGE_FILE != "")
            $readmemh(IMAGE_FILE, image);
    end

    assign memory_valid = !reset && !done;
    assign memory_write = 1'b1;
    assign memory_write_strobe = 8'hff;
    assign memory_address = DRAM_BASE + ({{(64-INDEX_BITS){1'b0}}, index} << 3);
    assign memory_write_data = image[index];

    always @(posedge clk) begin
        if (reset) begin
            index <= 0;
            done <= 1'b0;
        end else if (!done && memory_ready) begin
            if (index == IMAGE_WORDS - 1)
                done <= 1'b1;
            else
                index <= index + 1'b1;
        end
    end
endmodule
