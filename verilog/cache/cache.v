`timescale 1ns/1ps
module cache #(
    parameter integer LINE_COUNT = 16,
    parameter integer INDEX_BITS = 4,
    parameter [63:0] UNCACHED_BASE = 64'hf0000000,
    parameter [63:0] UNCACHED_MASK = 64'hfffffffff0000000
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        request_valid,
    input  wire        request_write,
    input  wire [7:0]  request_write_strobe,
    input  wire [63:0] request_address,
    input  wire [63:0] request_write_data,
    output wire        request_ready,
    output wire [63:0] request_read_data,
    output wire        memory_valid,
    output wire        memory_write,
    output wire [7:0]  memory_write_strobe,
    output wire [63:0] memory_address,
    output wire [63:0] memory_write_data,
    input  wire        memory_ready,
    input  wire [63:0] memory_read_data
);
    localparam STATE_IDLE = 2'd0;
    localparam STATE_WRITEBACK = 2'd1;
    localparam STATE_REFILL = 2'd2;
    localparam STATE_REPLAY = 2'd3;

    reg [1:0] state;
    reg valid_bits [0:LINE_COUNT-1];
    reg dirty_bits [0:LINE_COUNT-1];
    reg [63-INDEX_BITS-3:0] tags [0:LINE_COUNT-1];
    reg [63:0] lines [0:LINE_COUNT-1];
    reg pending_write;
    reg [7:0] pending_strobe;
    reg [63:0] pending_address;
    reg [63:0] pending_data;
    integer index;
    integer byte_index;

    wire [INDEX_BITS-1:0] request_index = request_address[INDEX_BITS+2:3];
    wire [63-INDEX_BITS-3:0] request_tag = request_address[63:INDEX_BITS+3];
    wire request_uncached = (request_address & UNCACHED_MASK) == UNCACHED_BASE;
    wire request_hit = valid_bits[request_index] && tags[request_index] == request_tag;

    wire [INDEX_BITS-1:0] pending_index = pending_address[INDEX_BITS+2:3];
    wire [63-INDEX_BITS-3:0] pending_tag = pending_address[63:INDEX_BITS+3];
    wire pending_uncached = (pending_address & UNCACHED_MASK) == UNCACHED_BASE;

    wire idle_uncached = state == STATE_IDLE && request_valid && request_uncached;
    wire idle_hit = state == STATE_IDLE && request_valid && !request_uncached && request_hit;
    assign request_ready = state == STATE_REPLAY || idle_hit || (idle_uncached && memory_ready);
    assign request_read_data = state == STATE_REPLAY ? lines[pending_index] :
                               idle_hit ? lines[request_index] :
                               idle_uncached ? memory_read_data : 64'b0;
    assign memory_valid = idle_uncached || state == STATE_WRITEBACK || state == STATE_REFILL;
    assign memory_write = idle_uncached ? request_write : state == STATE_WRITEBACK;
    assign memory_write_strobe = idle_uncached ? request_write_strobe :
                                 state == STATE_WRITEBACK ? 8'hff : 8'b0;
    assign memory_address = idle_uncached ? request_address :
                            state == STATE_WRITEBACK ? {tags[pending_index], pending_index, 3'b000} :
                            state == STATE_REFILL ? {pending_address[63:3], 3'b000} : 64'b0;
    assign memory_write_data = idle_uncached ? request_write_data :
                               state == STATE_WRITEBACK ? lines[pending_index] : 64'b0;

    always @(posedge clk) begin
        if (reset) begin
            state <= STATE_IDLE;
            pending_write <= 1'b0;
            pending_strobe <= 0;
            pending_address <= 0;
            pending_data <= 0;
            for (index = 0; index < LINE_COUNT; index = index + 1) begin
                valid_bits[index] <= 1'b0;
                dirty_bits[index] <= 1'b0;
                tags[index] <= 0;
                lines[index] <= 0;
            end
        end else begin
            case (state)
                STATE_IDLE: if (request_valid && !request_uncached) begin
                    if (request_hit) begin
                        if (request_write) begin
                            for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                                if (request_write_strobe[byte_index])
                                    lines[request_index][byte_index*8 +: 8] <=
                                        request_write_data[byte_index*8 +: 8];
                            dirty_bits[request_index] <= 1'b1;
                        end
                    end else begin
                        pending_write <= request_write;
                        pending_strobe <= request_write_strobe;
                        pending_address <= request_address;
                        pending_data <= request_write_data;
                        state <= valid_bits[request_index] && dirty_bits[request_index] ?
                                 STATE_WRITEBACK : STATE_REFILL;
                    end
                end
                STATE_WRITEBACK: if (memory_ready) begin
                    dirty_bits[pending_index] <= 1'b0;
                    state <= STATE_REFILL;
                end
                STATE_REFILL: if (memory_ready) begin
                    lines[pending_index] <= memory_read_data;
                    tags[pending_index] <= pending_tag;
                    valid_bits[pending_index] <= 1'b1;
                    dirty_bits[pending_index] <= pending_write;
                    if (pending_write)
                        for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                            if (pending_strobe[byte_index])
                                lines[pending_index][byte_index*8 +: 8] <=
                                    pending_data[byte_index*8 +: 8];
                    state <= STATE_REPLAY;
                end
                STATE_REPLAY: state <= STATE_IDLE;
            endcase
        end
    end
endmodule
