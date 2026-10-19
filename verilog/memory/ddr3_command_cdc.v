`timescale 1ns/1ps
// One outstanding command crosses two clock domains. The source payload is
// held until the response toggle returns; response data is held until the next
// command. Only toggles and initialization status pass through synchronizers.
// reset must reset BOTH domains together, not one side of an active transfer.
module ddr3_command_cdc (
    input wire source_clk,
    input wire controller_clk,
    input wire reset,
    input wire source_read,
    input wire source_write,
    input wire source_refresh,
    input wire [25:0] source_address,
    input wire [15:0] source_write_data,
    output wire source_init_done,
    output wire source_busy,
    output reg source_data_ready,
    output reg [15:0] source_read_data,
    input wire controller_init_done,
    input wire controller_busy,
    input wire controller_data_ready,
    input wire [15:0] controller_read_data,
    output reg controller_read,
    output reg controller_write,
    output reg controller_refresh,
    output wire [25:0] controller_address,
    output wire [15:0] controller_write_data
);
    // Asynchronous assertion, independently synchronized reset release.
    (* async_reg = "true" *) reg [1:0] source_reset_pipe = 2'b11;
    (* async_reg = "true" *) reg [1:0] controller_reset_pipe = 2'b11;
    always @(posedge source_clk or posedge reset)
        if (reset) source_reset_pipe <= 2'b11;
        else source_reset_pipe <= {source_reset_pipe[0], 1'b0};
    always @(posedge controller_clk or posedge reset)
        if (reset) controller_reset_pipe <= 2'b11;
        else controller_reset_pipe <= {controller_reset_pipe[0], 1'b0};

    reg request_toggle;
    reg response_toggle;
    reg pending;
    reg [2:0] command;
    reg [25:0] address;
    reg [15:0] write_data;
    reg [15:0] response_data;
    (* async_reg = "true" *) reg [1:0] request_sync;
    (* async_reg = "true" *) reg [1:0] response_sync;
    (* async_reg = "true" *) reg [1:0] init_sync;
    assign source_init_done = init_sync[1] && !source_reset_pipe[1];
    assign source_busy = pending || !source_init_done;
    assign controller_address = address;
    assign controller_write_data = write_data;

    always @(posedge source_clk) begin
        if (source_reset_pipe[1]) begin
            request_toggle <= 0;
            response_sync <= 0;
            init_sync <= 0;
            pending <= 0;
            command <= 0;
            address <= 0;
            write_data <= 0;
            source_data_ready <= 0;
            source_read_data <= 0;
        end else begin
            response_sync <= {response_sync[0], response_toggle};
            init_sync <= {init_sync[0], controller_init_done};
            source_data_ready <= 0;
            if (pending && response_sync[1] == request_toggle) begin
                source_read_data <= response_data;
                source_data_ready <= command[2];
                pending <= 0;
            end else if (!source_busy && (source_read || source_write || source_refresh)) begin
                command <= {source_read, source_write, source_refresh};
                address <= source_address;
                write_data <= source_write_data;
                request_toggle <= ~request_toggle;
                pending <= 1;
            end
        end
    end

    localparam WAIT_REQUEST = 2'd0, WAIT_BUSY = 2'd1, WAIT_COMPLETE = 2'd2;
    reg [1:0] state;
    reg read_pending;
    reg read_captured;
    always @(posedge controller_clk) begin
        if (controller_reset_pipe[1]) begin
            request_sync <= 0;
            response_toggle <= 0;
            response_data <= 0;
            controller_read <= 0;
            controller_write <= 0;
            controller_refresh <= 0;
            state <= WAIT_REQUEST;
            read_pending <= 0;
            read_captured <= 0;
        end else begin
            request_sync <= {request_sync[0], request_toggle};
            controller_read <= 0;
            controller_write <= 0;
            controller_refresh <= 0;
            case (state)
                WAIT_REQUEST: if (request_sync[1] != response_toggle &&
                                  controller_init_done && !controller_busy) begin
                    {controller_read, controller_write, controller_refresh} <= command;
                    read_pending <= command[2];
                    read_captured <= 0;
                    state <= WAIT_BUSY;
                end
                WAIT_BUSY: begin
                    if (read_pending && controller_data_ready) begin
                        response_data <= controller_read_data;
                        read_captured <= 1;
                    end
                    if (controller_busy) state <= WAIT_COMPLETE;
                end
                WAIT_COMPLETE: begin
                    if (read_pending && controller_data_ready) begin
                        response_data <= controller_read_data;
                        read_captured <= 1;
                    end
                    if (!controller_busy && (!read_pending || read_captured || controller_data_ready)) begin
                        response_toggle <= request_sync[1];
                        state <= WAIT_REQUEST;
                    end
                end
                default: state <= WAIT_REQUEST;
            endcase
        end
    end
endmodule
