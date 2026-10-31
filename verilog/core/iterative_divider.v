`timescale 1ns/1ps
// One restoring-division step per clock. The same datapath produces quotient
// and remainder for signed/unsigned RV64 and RV64W instructions.
module iterative_divider (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire        accept,
    input  wire        word_mode,
    input  wire        signed_mode,
    input  wire        remainder_mode,
    input  wire [63:0] dividend,
    input  wire [63:0] divisor,
    output reg         busy,
    output reg         done,
    output reg  [63:0] result
);
    reg [63:0] quotient;
    reg [64:0] partial_remainder;
    reg [63:0] divisor_magnitude;
    reg [6:0] steps_left;
    reg negate_quotient;
    reg negate_remainder;
    reg saved_word_mode;
    reg saved_remainder_mode;

    wire [63:0] divisor_value = word_mode ? {32'b0, divisor[31:0]} : divisor;
    wire dividend_negative = signed_mode && (word_mode ? dividend[31] : dividend[63]);
    wire divisor_negative = signed_mode && (word_mode ? divisor[31] : divisor[63]);
    wire [31:0] dividend_word_abs = dividend_negative ? -dividend[31:0] : dividend[31:0];
    wire [31:0] divisor_word_abs = divisor_negative ? -divisor[31:0] : divisor[31:0];
    wire [63:0] dividend_magnitude = word_mode ? {32'b0, dividend_word_abs} :
                                     (dividend_negative ? -dividend : dividend);
    wire [63:0] divisor_abs = word_mode ? {32'b0, divisor_word_abs} :
                              (divisor_negative ? -divisor : divisor);

    wire [64:0] shifted_remainder = {partial_remainder[63:0], quotient[63]};
    wire subtract = shifted_remainder >= {1'b0, divisor_magnitude};
    wire [64:0] next_remainder = subtract ?
        shifted_remainder - {1'b0, divisor_magnitude} : shifted_remainder;
    wire [63:0] next_quotient = {quotient[62:0], subtract};
    wire [63:0] signed_quotient = negate_quotient ? -next_quotient : next_quotient;
    wire [63:0] signed_remainder = negate_remainder ? -next_remainder[63:0] :
                                    next_remainder[63:0];
    wire [63:0] final_value = saved_remainder_mode ? signed_remainder : signed_quotient;

    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            done <= 1'b0;
            result <= 0;
            quotient <= 0;
            partial_remainder <= 0;
            divisor_magnitude <= 0;
            steps_left <= 0;
            negate_quotient <= 1'b0;
            negate_remainder <= 1'b0;
            saved_word_mode <= 1'b0;
            saved_remainder_mode <= 1'b0;
        end else if (accept) begin
            done <= 1'b0;
        end else if (start && !busy && !done) begin
            if (divisor_value == 0) begin
                result <= remainder_mode ?
                    (word_mode ? {{32{dividend[31]}}, dividend[31:0]} : dividend) :
                    64'hffffffffffffffff;
                done <= 1'b1;
            end else begin
                quotient <= word_mode ? {dividend_magnitude[31:0], 32'b0} :
                            dividend_magnitude;
                partial_remainder <= 0;
                divisor_magnitude <= divisor_abs;
                steps_left <= word_mode ? 7'd32 : 7'd64;
                negate_quotient <= dividend_negative ^ divisor_negative;
                negate_remainder <= dividend_negative;
                saved_word_mode <= word_mode;
                saved_remainder_mode <= remainder_mode;
                busy <= 1'b1;
            end
        end else if (busy) begin
            quotient <= next_quotient;
            partial_remainder <= next_remainder;
            steps_left <= steps_left - 1'b1;
            if (steps_left == 1) begin
                result <= saved_word_mode ? {{32{final_value[31]}}, final_value[31:0]} :
                          final_value;
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end
endmodule
