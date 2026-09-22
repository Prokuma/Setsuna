`timescale 1ns/1ps
// Functional model of the 16-bit DDR controller command interface. It is
// used by the board-level RTL test; timing calibration and DDR signaling are
// intentionally left to the hardware PHY.
module ddr3_controller_model #(
    parameter integer WORD_COUNT = 4096,
    parameter integer INIT_CYCLES = 8,
    parameter integer ACCESS_CYCLES = 3
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        read_command,
    input  wire        write_command,
    input  wire        refresh_command,
    input  wire [25:0] address,
    input  wire [15:0] write_data,
    output reg  [15:0] read_data,
    output reg         data_ready,
    output reg         busy,
    output reg         init_done
);
    localparam integer INIT_WIDTH = INIT_CYCLES <= 1 ? 1 : $clog2(INIT_CYCLES + 1);
    localparam integer ACCESS_WIDTH = ACCESS_CYCLES <= 1 ? 1 : $clog2(ACCESS_CYCLES + 1);
    reg [15:0] memory [0:WORD_COUNT-1];
    reg [INIT_WIDTH-1:0] init_count;
    reg [ACCESS_WIDTH-1:0] access_count;
    reg pending_read;
    reg [25:0] pending_address;
    integer index;

    always @(posedge clk) begin
        data_ready <= 1'b0;
        if (reset) begin
            init_count <= 0;
            access_count <= 0;
            pending_read <= 1'b0;
            pending_address <= 0;
            read_data <= 0;
            busy <= 1'b1;
            init_done <= 1'b0;
            for (index = 0; index < WORD_COUNT; index = index + 1)
                memory[index] <= 0;
        end else if (!init_done) begin
            if (init_count == INIT_CYCLES - 1) begin
                init_done <= 1'b1;
                busy <= 1'b0;
            end else begin
                init_count <= init_count + 1'b1;
            end
        end else if (!busy) begin
            if (read_command || write_command || refresh_command) begin
                busy <= 1'b1;
                access_count <= ACCESS_CYCLES;
                pending_read <= read_command;
                pending_address <= address;
                if (write_command && address < WORD_COUNT)
                    memory[address] <= write_data;
            end
        end else if (access_count != 0) begin
            access_count <= access_count - 1'b1;
            if (access_count == 1) begin
                busy <= 1'b0;
                if (pending_read) begin
                    read_data <= pending_address < WORD_COUNT ? memory[pending_address] : 16'b0;
                    data_ready <= 1'b1;
                end
                pending_read <= 1'b0;
            end
        end
    end
endmodule
