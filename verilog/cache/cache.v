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
    localparam STATE_IDLE = 3'd0;
    localparam STATE_LOOKUP = 3'd1;
    localparam STATE_WRITEBACK = 3'd2;
    localparam STATE_REFILL = 3'd3;
    localparam STATE_REPLAY = 3'd4;

    reg [2:0] state;
    reg valid_bits [0:LINE_COUNT-1];
    reg dirty_bits [0:LINE_COUNT-1];
    (* ram_style = "block" *) reg [63-INDEX_BITS-3:0] tags [0:LINE_COUNT-1];
    reg [63-INDEX_BITS-3:0] tag_read_data;
    // Data and tags use block RAM; valid/dirty state remains in FFs.
    // A synchronous read and one mutually exclusive byte-enabled write port
    // match the GW2A BSRAM primitives; no reset touches the RAM contents.
    (* ram_style = "block" *) reg [63:0] lines [0:LINE_COUNT-1];
    reg [63:0] line_read_data;
    reg [63:0] replay_data;
    reg pending_write;
    reg [7:0] pending_strobe;
    reg [63:0] pending_address;
    reg [63:0] pending_data;
    integer index;
    integer byte_index;

    wire [INDEX_BITS-1:0] request_index = request_address[INDEX_BITS+2:3];
    wire request_uncached = (request_address & UNCACHED_MASK) == UNCACHED_BASE;
    wire [INDEX_BITS-1:0] pending_index = pending_address[INDEX_BITS+2:3];
    wire [63-INDEX_BITS-3:0] pending_tag = pending_address[63:INDEX_BITS+3];
    wire lookup_hit = valid_bits[pending_index] && tag_read_data == pending_tag;
    wire idle_uncached = state == STATE_IDLE && request_valid && request_uncached;
    wire lookup_write = state == STATE_LOOKUP && lookup_hit && pending_write;
    wire refill_write = state == STATE_REFILL && memory_ready;

    assign request_ready = (state == STATE_LOOKUP && lookup_hit) ||
                           state == STATE_REPLAY || (idle_uncached && memory_ready);
    assign request_read_data = state == STATE_LOOKUP && lookup_hit ? line_read_data :
                               state == STATE_REPLAY ? replay_data :
                               idle_uncached ? memory_read_data : 64'b0;
    assign memory_valid = idle_uncached || state == STATE_WRITEBACK || state == STATE_REFILL;
    assign memory_write = idle_uncached ? request_write : state == STATE_WRITEBACK;
    assign memory_write_strobe = idle_uncached ? request_write_strobe :
                                 state == STATE_WRITEBACK ? 8'hff : 8'b0;
    assign memory_address = idle_uncached ? request_address :
                            state == STATE_WRITEBACK ? {tag_read_data, pending_index, 3'b000} :
                            state == STATE_REFILL ? {pending_address[63:3], 3'b000} : 64'b0;
    assign memory_write_data = idle_uncached ? request_write_data :
                               state == STATE_WRITEBACK ? line_read_data : 64'b0;

    // The lookup read occurs at the same edge that captures the request. No
    // combinational read, per-line reset, or read-modify-write loop is used.
    always @(posedge clk) begin
        if (lookup_write || refill_write) begin
            for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1)
                if (refill_write || pending_strobe[byte_index])
                    lines[pending_index][byte_index*8 +: 8] <=
                        refill_write && (!pending_write || !pending_strobe[byte_index]) ?
                        memory_read_data[byte_index*8 +: 8] :
                        pending_data[byte_index*8 +: 8];
        end else if (state == STATE_IDLE && request_valid && !request_uncached) begin
            line_read_data <= lines[request_index];
        end
    end

    // The tag read runs alongside the data read on request capture. A tag is
    // written only on refill; valid bits make its power-up contents irrelevant.
    always @(posedge clk) begin
        if (refill_write)
            tags[pending_index] <= pending_tag;
        else if (state == STATE_IDLE && request_valid && !request_uncached)
            tag_read_data <= tags[request_index];
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= STATE_IDLE;
            pending_write <= 1'b0;
            pending_strobe <= 0;
            pending_address <= 0;
            pending_data <= 0;
            replay_data <= 0;
            for (index = 0; index < LINE_COUNT; index = index + 1) begin
                valid_bits[index] <= 1'b0;
                dirty_bits[index] <= 1'b0;
            end
        end else begin
            case (state)
                STATE_IDLE: if (request_valid && !request_uncached) begin
                    pending_write <= request_write;
                    pending_strobe <= request_write_strobe;
                    pending_address <= request_address;
                    pending_data <= request_write_data;
                    state <= STATE_LOOKUP;
                end
                STATE_LOOKUP: begin
                    if (lookup_hit) begin
                        if (pending_write)
                            dirty_bits[pending_index] <= 1'b1;
                        state <= STATE_IDLE;
                    end else begin
                        state <= valid_bits[pending_index] && dirty_bits[pending_index] ?
                                 STATE_WRITEBACK : STATE_REFILL;
                    end
                end
                STATE_WRITEBACK: if (memory_ready) begin
                    dirty_bits[pending_index] <= 1'b0;
                    state <= STATE_REFILL;
                end
                STATE_REFILL: if (memory_ready) begin
                    replay_data <= memory_read_data;
                    if (pending_write)
                        for (index = 0; index < 8; index = index + 1)
                            if (pending_strobe[index])
                                replay_data[index*8 +: 8] <= pending_data[index*8 +: 8];
                    valid_bits[pending_index] <= 1'b1;
                    dirty_bits[pending_index] <= pending_write;
                    state <= STATE_REPLAY;
                end
                STATE_REPLAY: state <= STATE_IDLE;
                default: state <= STATE_IDLE;
            endcase
        end
    end
endmodule
