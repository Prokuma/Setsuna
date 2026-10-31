`timescale 1ns/1ps
// Copy the block-ROM image to DRAM, then read every word back before releasing
// the processor. A lost response or mismatch latches failure until reset.
module dram_boot_loader #(
    parameter [63:0] DRAM_BASE = 64'h0000000080000000,
    parameter integer IMAGE_WORDS = 1,
    parameter IMAGE_FILE = "",
    parameter integer TIMEOUT_CYCLES = 27000000
) (
    input  wire        clk,
    input  wire        reset,
    output wire        memory_valid,
    output wire        memory_write,
    output wire [7:0]  memory_write_strobe,
    output wire [63:0] memory_address,
    output wire [63:0] memory_write_data,
    input  wire        memory_ready,
    input  wire [63:0] memory_read_data,
    output reg         done,
    output reg         verifying,
    output reg         failed,
    output reg  [1:0]  error_code
);
    localparam integer INDEX_BITS = IMAGE_WORDS <= 1 ? 1 : $clog2(IMAGE_WORDS);
    localparam integer TIMEOUT_BITS = TIMEOUT_CYCLES <= 1 ? 1 : $clog2(TIMEOUT_CYCLES);
    localparam LOAD = 2'd0, WRITE = 2'd1, READ = 2'd2;
    (* ram_style = "block" *) reg [63:0] image [0:IMAGE_WORDS-1];
    reg [63:0] image_data;
    reg [INDEX_BITS-1:0] index;
    reg [TIMEOUT_BITS-1:0] timeout_count;
    reg [1:0] state;

    initial begin
        if (IMAGE_FILE != "")
            $readmemh(IMAGE_FILE, image);
    end

    always @(posedge clk) image_data <= image[index];

    assign memory_valid = !reset && !done && !failed && state != LOAD;
    assign memory_write = state == WRITE;
    assign memory_write_strobe = 8'hff;
    assign memory_address = DRAM_BASE + ({{(64-INDEX_BITS){1'b0}}, index} << 3);
    assign memory_write_data = image_data;

    always @(posedge clk) begin
        if (reset) begin
            index <= 0;
            done <= 1'b0;
            verifying <= 1'b0;
            failed <= 1'b0;
            error_code <= 0;
            timeout_count <= 0;
            state <= LOAD;
        end else if (!done && !failed) begin
            if (state == LOAD) begin
                state <= verifying ? READ : WRITE;
                timeout_count <= 0;
            end else if (memory_ready) begin
                timeout_count <= 0;
                if (verifying && memory_read_data != image_data) begin
                    failed <= 1'b1;
                    error_code <= 2'd1;
                end else if (index == IMAGE_WORDS - 1) begin
                    if (verifying) done <= 1'b1;
                    else begin
                        index <= 0;
                        verifying <= 1'b1;
                        state <= LOAD;
                    end
                end else begin
                    index <= index + 1'b1;
                    state <= LOAD;
                end
            end else if (timeout_count == TIMEOUT_CYCLES - 1) begin
                failed <= 1'b1;
                error_code <= verifying ? 2'd3 : 2'd2;
            end else timeout_count <= timeout_count + 1'b1;
        end
    end
endmodule
