`timescale 1ns/1ps
// Serializes the independent instruction and data cache memory ports.
// Data has priority when both ports request an idle backend.
module memory_arbiter (
    input  wire        clk,
    input  wire        reset,
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
    output wire        memory_valid,
    output wire        memory_write,
    output wire [7:0]  memory_write_strobe,
    output wire [63:0] memory_address,
    output wire [63:0] memory_write_data,
    input  wire        memory_ready,
    input  wire [63:0] memory_read_data
);
    reg active;
    reg owner_data;
    reg request_write;
    reg [7:0] request_write_strobe;
    reg [63:0] request_address;
    reg [63:0] request_write_data;

    assign instruction_ready = active && !owner_data && memory_ready;
    assign instruction_read_data = memory_read_data;
    assign data_ready = active && owner_data && memory_ready;
    assign data_read_data = memory_read_data;
    assign memory_valid = active;
    assign memory_write = request_write;
    assign memory_write_strobe = request_write_strobe;
    assign memory_address = request_address;
    assign memory_write_data = request_write_data;

    always @(posedge clk) begin
        if (reset) begin
            active <= 1'b0;
            owner_data <= 1'b0;
            request_write <= 1'b0;
            request_write_strobe <= 0;
            request_address <= 0;
            request_write_data <= 0;
        end else if (active) begin
            if (memory_ready)
                active <= 1'b0;
        end else if (data_valid) begin
            active <= 1'b1;
            owner_data <= 1'b1;
            request_write <= data_write;
            request_write_strobe <= data_write_strobe;
            request_address <= data_address;
            request_write_data <= data_write_data;
        end else if (instruction_valid) begin
            active <= 1'b1;
            owner_data <= 1'b0;
            request_write <= 1'b0;
            request_write_strobe <= 0;
            request_address <= instruction_address;
            request_write_data <= 0;
        end
    end
endmodule
