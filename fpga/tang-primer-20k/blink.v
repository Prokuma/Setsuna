// Tang Primer 20K Dock: active-low walking LEDs, one step every half second.
module blink #(
    parameter integer CLOCK_HZ = 27000000
)(
    input wire clk,
    output wire [5:0] led_n
);
    localparam integer HALF_PERIOD = CLOCK_HZ / 2;
    localparam integer COUNT_WIDTH = (HALF_PERIOD > 1) ? $clog2(HALF_PERIOD) : 1;
    reg [COUNT_WIDTH-1:0] count = 0;
    reg [5:0] active = 6'b000001;
    always @(posedge clk) begin
        if (count == HALF_PERIOD - 1) begin
            count <= 0;
            active <= {active[4:0], active[5]};
        end else begin
            count <= count + 1'b1;
        end
    end
    assign led_n = ~active;
endmodule
