`timescale 1ns/1ps
module register_file (
    input  wire        clk,
    input  wire        reset,
    input  wire [4:0]  rs1,
    input  wire [4:0]  rs2,
    output wire [63:0] rs1_data,
    output wire [63:0] rs2_data,
    input  wire        write_enable,
    input  wire [4:0]  write_rd,
    input  wire [63:0] write_data,
    input  wire [4:0]  debug_addr,
    output wire [63:0] debug_data
);
    reg [63:0] registers [0:31];
    integer index;

    assign rs1_data = (rs1 == 0) ? 64'b0 :
                      (write_enable && write_rd == rs1 && write_rd != 0) ? write_data :
                      registers[rs1];
    assign rs2_data = (rs2 == 0) ? 64'b0 :
                      (write_enable && write_rd == rs2 && write_rd != 0) ? write_data :
                      registers[rs2];
    assign debug_data = (debug_addr == 0) ? 64'b0 : registers[debug_addr];

    always @(posedge clk) begin
        if (reset) begin
            for (index = 0; index < 32; index = index + 1)
                registers[index] <= 64'b0;
        end else if (write_enable && write_rd != 0) begin
            registers[write_rd] <= write_data;
        end
        registers[0] <= 64'b0;
    end
endmodule
