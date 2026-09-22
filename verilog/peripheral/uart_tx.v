`timescale 1ns/1ps
module uart_tx #(
    parameter integer CLOCK_HZ = 27000000,
    parameter integer BAUD = 115200
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       write_enable,
    input  wire [7:0] write_data,
    output reg        tx,
    output reg        busy
);
    localparam integer DIVISOR = CLOCK_HZ / BAUD;
    localparam integer COUNTER_WIDTH = $clog2(DIVISOR);
    reg [COUNTER_WIDTH-1:0] baud_counter;
    reg [3:0] bit_count;
    reg [9:0] shift_register;

    always @(posedge clk) begin
        if (reset) begin
            tx <= 1'b1;
            busy <= 1'b0;
            baud_counter <= 0;
            bit_count <= 0;
            shift_register <= 10'h3ff;
        end else if (!busy) begin
            tx <= 1'b1;
            if (write_enable) begin
                shift_register <= {1'b1, write_data, 1'b0};
                tx <= 1'b0;
                busy <= 1'b1;
                baud_counter <= DIVISOR - 1;
                bit_count <= 0;
            end
        end else if (baud_counter == 0) begin
            shift_register <= {1'b1, shift_register[9:1]};
            tx <= shift_register[1];
            baud_counter <= DIVISOR - 1;
            if (bit_count == 9) begin
                busy <= 1'b0;
                tx <= 1'b1;
            end else bit_count <= bit_count + 1'b1;
        end else baud_counter <= baud_counter - 1'b1;
    end
endmodule
