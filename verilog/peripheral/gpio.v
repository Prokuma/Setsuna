`timescale 1ns/1ps
module gpio #(
    parameter integer WIDTH = 8
) (
    input  wire             clk,
    input  wire             reset,
    input  wire             write_enable,
    input  wire [7:0]       write_strobe,
    input  wire [63:0]      write_data,
    input  wire [WIDTH-1:0] input_pins,
    output reg  [WIDTH-1:0] output_pins,
    output wire [63:0]      read_data
);
    assign read_data = {{(64-WIDTH){1'b0}}, input_pins};
    integer byte_index;
    always @(posedge clk) begin
        if (reset)
            output_pins <= 0;
        else if (write_enable)
            for (byte_index = 0; byte_index < (WIDTH+7)/8; byte_index = byte_index + 1)
                if (write_strobe[byte_index])
                    output_pins[byte_index*8 +: 8] <= write_data[byte_index*8 +: 8];
    end
endmodule
