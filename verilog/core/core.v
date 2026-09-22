`timescale 1ns/1ps
module core #(
    parameter [63:0] RESET_VECTOR = 64'h0000000080000000,
    parameter integer ENABLE_M = 1
) (
    input  wire        clk,
    input  wire        reset,

    output wire        instruction_valid,
    output wire [63:0] instruction_address,
    input  wire        instruction_ready,
    input  wire [31:0] instruction_data,

    output wire        data_valid,
    output wire        data_write,
    output wire [7:0]  data_write_strobe,
    output wire [63:0] data_address,
    output wire [63:0] data_write_data,
    input  wire        data_ready,
    input  wire [63:0] data_read_data,

    input  wire [4:0]  debug_register_address,
    output wire [63:0] debug_register_data,
    output reg  [63:0] cycle_count,
    output reg  [63:0] retired_count,
    output reg         halted,
    output reg         trap,
    output reg  [63:0] trap_pc,
    output reg  [63:0] trap_cause
);
    reg [63:0] fetch_pc;
    reg fault_pending;

    reg ifid_valid;
    reg [63:0] ifid_pc;
    reg [31:0] ifid_instruction;

    wire [6:0] decode_opcode;
    wire [2:0] decode_funct3;
    wire [6:0] decode_funct7;
    wire [4:0] decode_rd;
    wire [4:0] decode_rs1;
    wire [4:0] decode_rs2;
    wire [63:0] decode_immediate;
    wire decode_uses_rs1;
    wire decode_uses_rs2;
    wire decode_writes_rd;
    wire decode_memory_read;
    wire decode_memory_write;
    wire decode_illegal;

    reg idex_valid;
    reg [63:0] idex_pc;
    reg [31:0] idex_instruction;
    reg [63:0] idex_immediate;
    reg [63:0] idex_rs1_data;
    reg [63:0] idex_rs2_data;
    reg [4:0] idex_rs1;
    reg [4:0] idex_rs2;
    reg [4:0] idex_rd;
    reg idex_writes_rd;
    reg idex_memory_read;
    reg idex_memory_write;
    reg idex_illegal;

    reg exmem_valid;
    reg [63:0] exmem_pc;
    reg [31:0] exmem_instruction;
    reg [63:0] exmem_result;
    reg [63:0] exmem_address;
    reg [63:0] exmem_store_data;
    reg [4:0] exmem_rd;
    reg exmem_writes_rd;
    reg exmem_memory_read;
    reg exmem_memory_write;
    reg exmem_illegal;

    reg memwb_valid;
    reg [63:0] memwb_pc;
    reg [31:0] memwb_instruction;
    reg [63:0] memwb_value;
    reg [4:0] memwb_rd;
    reg memwb_writes_rd;
    reg memwb_illegal;

    wire [63:0] register_rs1_data;
    wire [63:0] register_rs2_data;
    wire register_write_enable = memwb_valid && memwb_writes_rd && !memwb_illegal && !halted;

    register_file registers (
        .clk(clk), .reset(reset),
        .rs1(decode_rs1), .rs2(decode_rs2),
        .rs1_data(register_rs1_data), .rs2_data(register_rs2_data),
        .write_enable(register_write_enable), .write_rd(memwb_rd), .write_data(memwb_value),
        .debug_addr(debug_register_address), .debug_data(debug_register_data)
    );

    decode decoder (
        .instruction(ifid_instruction), .opcode(decode_opcode), .funct3(decode_funct3),
        .funct7(decode_funct7), .rd(decode_rd), .rs1(decode_rs1), .rs2(decode_rs2),
        .immediate(decode_immediate), .uses_rs1(decode_uses_rs1), .uses_rs2(decode_uses_rs2),
        .writes_rd(decode_writes_rd), .memory_read(decode_memory_read),
        .memory_write(decode_memory_write), .illegal(decode_illegal)
    );

    reg [63:0] execute_operand_a;
    reg [63:0] execute_operand_b;
    always @* begin
        execute_operand_a = idex_rs1_data;
        execute_operand_b = idex_rs2_data;
        if (memwb_valid && memwb_writes_rd && memwb_rd != 0 && memwb_rd == idex_rs1)
            execute_operand_a = memwb_value;
        if (memwb_valid && memwb_writes_rd && memwb_rd != 0 && memwb_rd == idex_rs2)
            execute_operand_b = memwb_value;
        if (exmem_valid && exmem_writes_rd && !exmem_memory_read && exmem_rd != 0 && exmem_rd == idex_rs1)
            execute_operand_a = exmem_result;
        if (exmem_valid && exmem_writes_rd && !exmem_memory_read && exmem_rd != 0 && exmem_rd == idex_rs2)
            execute_operand_b = exmem_result;
    end

    wire [63:0] execute_result;
    wire [63:0] execute_address;
    wire execute_redirect;
    wire [63:0] execute_redirect_pc;
    wire execute_illegal;
    execute #(.ENABLE_M(ENABLE_M)) execution_unit (
        .instruction(idex_instruction), .pc(idex_pc),
        .operand_a(execute_operand_a), .operand_b(execute_operand_b),
        .immediate(idex_immediate), .result(execute_result),
        .memory_address(execute_address), .redirect(execute_redirect),
        .redirect_pc(execute_redirect_pc), .illegal(execute_illegal)
    );

    wire [2:0] exmem_funct3 = exmem_instruction[14:12];
    wire [2:0] byte_offset = exmem_address[2:0];
    wire [63:0] shifted_store_data = exmem_store_data << (byte_offset * 8);
    reg [7:0] store_strobe;
    always @* begin
        case (exmem_funct3)
            3'h0: store_strobe = 8'h01 << byte_offset;
            3'h1: store_strobe = 8'h03 << byte_offset;
            3'h2: store_strobe = 8'h0f << byte_offset;
            3'h3: store_strobe = 8'hff;
            default: store_strobe = 8'h00;
        endcase
    end

    wire [63:0] shifted_load_data = data_read_data >> (byte_offset * 8);
    reg [63:0] loaded_value;
    always @* begin
        case (exmem_funct3)
            3'h0: loaded_value = {{56{shifted_load_data[7]}}, shifted_load_data[7:0]};
            3'h1: loaded_value = {{48{shifted_load_data[15]}}, shifted_load_data[15:0]};
            3'h2: loaded_value = {{32{shifted_load_data[31]}}, shifted_load_data[31:0]};
            3'h3: loaded_value = shifted_load_data;
            3'h4: loaded_value = {56'b0, shifted_load_data[7:0]};
            3'h5: loaded_value = {48'b0, shifted_load_data[15:0]};
            3'h6: loaded_value = {32'b0, shifted_load_data[31:0]};
            default: loaded_value = 64'b0;
        endcase
    end

    assign instruction_address = fetch_pc;
    assign data_valid = exmem_valid && (exmem_memory_read || exmem_memory_write) && !exmem_illegal;
    assign data_write = exmem_memory_write;
    assign data_write_strobe = store_strobe;
    assign data_address = exmem_address;
    assign data_write_data = shifted_store_data;

    wire memory_stall = data_valid && !data_ready;
    wire load_use_stall = ifid_valid && idex_valid && idex_memory_read && idex_rd != 0 &&
        ((decode_uses_rs1 && decode_rs1 == idex_rd) ||
         (decode_uses_rs2 && decode_rs2 == idex_rd));
    wire decode_control_flow = ifid_valid &&
        (decode_opcode == 7'h63 || decode_opcode == 7'h67 || decode_opcode == 7'h6f);
    wire execute_control_flow = idex_valid &&
        (idex_instruction[6:0] == 7'h63 || idex_instruction[6:0] == 7'h67 ||
         idex_instruction[6:0] == 7'h6f);
    wire execute_fault = idex_valid && (idex_illegal || execute_illegal ||
                         idex_instruction == 32'h00000073 ||
                         idex_instruction == 32'h00100073);
    wire frontend_stall = memory_stall || load_use_stall || execute_fault ||
                          decode_control_flow || execute_control_flow;
    assign instruction_valid = !reset && !halted && !fault_pending && !frontend_stall;

    always @(posedge clk) begin
        if (reset) begin
            fetch_pc <= RESET_VECTOR;
            ifid_valid <= 1'b0;
            idex_valid <= 1'b0;
            exmem_valid <= 1'b0;
            memwb_valid <= 1'b0;
            cycle_count <= 0;
            retired_count <= 0;
            halted <= 1'b0;
            trap <= 1'b0;
            trap_pc <= 0;
            trap_cause <= 0;
            fault_pending <= 1'b0;
        end else if (!halted) begin
            cycle_count <= cycle_count + 1;

            if (memwb_valid) begin
                if (memwb_illegal || memwb_instruction == 32'h00000073) begin
                    trap <= 1'b1;
                    trap_pc <= memwb_pc;
                    trap_cause <= memwb_illegal ? 64'd2 : 64'd11;
                    halted <= 1'b1;
                end else begin
                    retired_count <= retired_count + 1;
                    if (memwb_instruction == 32'h00100073)
                        halted <= 1'b1;
                end
            end

            if (memory_stall) begin
                memwb_valid <= 1'b0;
            end else begin
                memwb_valid <= exmem_valid;
                memwb_pc <= exmem_pc;
                memwb_instruction <= exmem_instruction;
                memwb_value <= exmem_memory_read ? loaded_value : exmem_result;
                memwb_rd <= exmem_rd;
                memwb_writes_rd <= exmem_writes_rd;
                memwb_illegal <= exmem_illegal;

                exmem_valid <= idex_valid;
                exmem_pc <= idex_pc;
                exmem_instruction <= idex_instruction;
                exmem_result <= execute_result;
                exmem_address <= execute_address;
                exmem_store_data <= execute_operand_b;
                exmem_rd <= idex_rd;
                exmem_writes_rd <= idex_writes_rd;
                exmem_memory_read <= idex_memory_read;
                exmem_memory_write <= idex_memory_write;
                exmem_illegal <= idex_illegal || execute_illegal;

                if (execute_fault) begin
                    fault_pending <= 1'b1;
                    idex_valid <= 1'b0;
                    ifid_valid <= 1'b0;
                end else if (idex_valid && execute_redirect) begin
                    fetch_pc <= execute_redirect_pc;
                    idex_valid <= 1'b0;
                    ifid_valid <= 1'b0;
                end else if (load_use_stall) begin
                    idex_valid <= 1'b0;
                end else begin
                    idex_valid <= ifid_valid;
                    idex_pc <= ifid_pc;
                    idex_instruction <= ifid_instruction;
                    idex_immediate <= decode_immediate;
                    idex_rs1_data <= register_rs1_data;
                    idex_rs2_data <= register_rs2_data;
                    idex_rs1 <= decode_rs1;
                    idex_rs2 <= decode_rs2;
                    idex_rd <= decode_rd;
                    idex_writes_rd <= decode_writes_rd;
                    idex_memory_read <= decode_memory_read;
                    idex_memory_write <= decode_memory_write;
                    idex_illegal <= decode_illegal;

                    if (instruction_ready && instruction_valid) begin
                        ifid_valid <= 1'b1;
                        ifid_pc <= fetch_pc;
                        ifid_instruction <= instruction_data;
                        fetch_pc <= fetch_pc + 4;
                    end else begin
                        ifid_valid <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
