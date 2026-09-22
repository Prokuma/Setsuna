`timescale 1ns/1ps
// Adapts Setsuna's 64-bit ready/valid memory port to the controller's
// single-16-bit-word command interface and schedules periodic refreshes.
module ddr3_bus_adapter #(
    parameter [63:0] DRAM_BASE = 64'h0000000080000000,
    parameter integer REFRESH_CYCLES = 778
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        controller_init_done,
    input  wire        request_valid,
    input  wire        request_write,
    input  wire [7:0]  request_write_strobe,
    input  wire [63:0] request_address,
    input  wire [63:0] request_write_data,
    output reg         request_ready,
    output reg  [63:0] request_read_data,
    output reg         controller_read,
    output reg         controller_write,
    output reg         controller_refresh,
    output wire [25:0] controller_address,
    output wire [15:0] controller_write_data,
    input  wire [15:0] controller_read_data,
    input  wire        controller_data_ready,
    input  wire        controller_busy
);
    localparam STATE_IDLE = 4'd0;
    localparam STATE_SELECT = 4'd1;
    localparam STATE_ISSUE_READ = 4'd2;
    localparam STATE_WAIT_READ = 4'd3;
    localparam STATE_ISSUE_WRITE = 4'd4;
    localparam STATE_WAIT_WRITE = 4'd5;
    localparam STATE_ISSUE_REFRESH = 4'd6;
    localparam STATE_WAIT_REFRESH = 4'd7;

    localparam integer REFRESH_WIDTH = REFRESH_CYCLES <= 1 ? 1 : $clog2(REFRESH_CYCLES + 1);
    reg [3:0] state;
    reg [1:0] chunk;
    reg pending_write;
    reg [7:0] pending_strobe;
    reg [63:0] pending_address;
    reg [63:0] pending_write_data;
    reg [15:0] merged_write_data;
    reg partial_write;
    reg operation_started;
    reg refresh_pending;
    reg [REFRESH_WIDTH-1:0] refresh_counter;

    wire [1:0] chunk_strobe = pending_strobe[chunk*2 +: 2];
    wire [15:0] chunk_write_data = pending_write_data[chunk*16 +: 16];
    wire [63:0] byte_offset = pending_address - DRAM_BASE;
    assign controller_address = byte_offset[26:1] + chunk;
    assign controller_write_data = partial_write ? merged_write_data : chunk_write_data;

    task advance_chunk;
        begin
            partial_write <= 1'b0;
            operation_started <= 1'b0;
            if (chunk == 2'd3) begin
                request_ready <= 1'b1;
                state <= STATE_IDLE;
            end else begin
                chunk <= chunk + 1'b1;
                state <= STATE_SELECT;
            end
        end
    endtask

    always @(posedge clk) begin
        if (reset) begin
            state <= STATE_IDLE;
            chunk <= 0;
            pending_write <= 1'b0;
            pending_strobe <= 0;
            pending_address <= 0;
            pending_write_data <= 0;
            merged_write_data <= 0;
            partial_write <= 1'b0;
            operation_started <= 1'b0;
            refresh_pending <= 1'b0;
            refresh_counter <= 0;
            request_ready <= 1'b0;
            request_read_data <= 0;
            controller_read <= 1'b0;
            controller_write <= 1'b0;
            controller_refresh <= 1'b0;
        end else begin
            request_ready <= 1'b0;
            controller_read <= 1'b0;
            controller_write <= 1'b0;
            controller_refresh <= 1'b0;

            if (controller_init_done) begin
                if (refresh_counter == REFRESH_CYCLES - 1) begin
                    refresh_counter <= 0;
                    refresh_pending <= 1'b1;
                end else begin
                    refresh_counter <= refresh_counter + 1'b1;
                end
            end else begin
                refresh_counter <= 0;
                refresh_pending <= 1'b0;
            end

            case (state)
                STATE_IDLE: begin
                    partial_write <= 1'b0;
                    operation_started <= 1'b0;
                    // Leave one acknowledgement cycle before sampling the next
                    // request, so a producer can advance its address/index.
                    if (!request_ready) begin
                        if (controller_init_done && refresh_pending) begin
                            state <= STATE_ISSUE_REFRESH;
                        end else if (controller_init_done && request_valid) begin
                            pending_write <= request_write;
                            pending_strobe <= request_write_strobe;
                            pending_address <= request_address;
                            pending_write_data <= request_write_data;
                            request_read_data <= 0;
                            chunk <= 0;
                            state <= STATE_SELECT;
                        end
                    end
                end
                STATE_SELECT: begin
                    operation_started <= 1'b0;
                    if (!pending_write)
                        state <= STATE_ISSUE_READ;
                    else if (chunk_strobe == 2'b00)
                        advance_chunk();
                    else if (chunk_strobe == 2'b11)
                        state <= STATE_ISSUE_WRITE;
                    else begin
                        partial_write <= 1'b1;
                        state <= STATE_ISSUE_READ;
                    end
                end
                STATE_ISSUE_READ: if (!controller_busy) begin
                    controller_read <= 1'b1;
                    operation_started <= 1'b0;
                    state <= STATE_WAIT_READ;
                end
                STATE_WAIT_READ: begin
                    if (controller_busy)
                        operation_started <= 1'b1;
                    if (controller_data_ready) begin
                        if (partial_write) begin
                            merged_write_data <= {
                                chunk_strobe[1] ? chunk_write_data[15:8] : controller_read_data[15:8],
                                chunk_strobe[0] ? chunk_write_data[7:0] : controller_read_data[7:0]
                            };
                            operation_started <= 1'b0;
                            state <= STATE_ISSUE_WRITE;
                        end else begin
                            request_read_data[chunk*16 +: 16] <= controller_read_data;
                            advance_chunk();
                        end
                    end
                end
                STATE_ISSUE_WRITE: if (!controller_busy) begin
                    controller_write <= 1'b1;
                    operation_started <= 1'b0;
                    state <= STATE_WAIT_WRITE;
                end
                STATE_WAIT_WRITE: begin
                    if (controller_busy)
                        operation_started <= 1'b1;
                    else if (operation_started)
                        advance_chunk();
                end
                STATE_ISSUE_REFRESH: if (!controller_busy) begin
                    controller_refresh <= 1'b1;
                    operation_started <= 1'b0;
                    refresh_pending <= 1'b0;
                    state <= STATE_WAIT_REFRESH;
                end
                STATE_WAIT_REFRESH: begin
                    if (controller_busy)
                        operation_started <= 1'b1;
                    else if (operation_started) begin
                        operation_started <= 1'b0;
                        state <= STATE_IDLE;
                    end
                end
                default: state <= STATE_IDLE;
            endcase
        end
    end
endmodule
