`timescale 1ns/1ps
module boot_rom_tb;
    reg clk = 0, reset = 1;
    always #5 clk = ~clk;
    reg iv = 0, dv = 0, dw = 0;
    reg [63:0] ia = 64'h80000000, da = 64'h80000008;
    wire ir, dr;
    wire [63:0] idata, ddata;
    boot_rom #(.IMAGE_WORDS(6),
        .IMAGE_FILE("fpga/tang-primer-20k/demo_program_sim.hex")) dut (
        .clk(clk), .reset(reset), .instruction_valid(iv), .instruction_address(ia),
        .instruction_ready(ir), .instruction_read_data(idata),
        .data_valid(dv), .data_write(dw), .data_address(da),
        .data_ready(dr), .data_read_data(ddata)
    );
    initial begin
        repeat (2) @(negedge clk);
        if (ir || dr) $fatal(1, "ack during reset");
        reset = 0; iv = 1; dv = 1;
        @(negedge clk);
        if (!ir || !dr || idata !== 64'h01c0909300f00093 ||
            ddata !== 64'h0020b02300000113) $fatal(1, "dual ROM reads");
        iv = 0; dv = 0;
        @(negedge clk);
        dv = 1; dw = 1;
        @(negedge clk);
        if (!dr) $fatal(1, "ROM store not acknowledged");
        dv = 0;
        @(negedge clk);
        dv = 1; dw = 0;
        @(negedge clk);
        if (!dr || ddata !== 64'h0020b02300000113) $fatal(1, "ROM changed by store");
        dv = 0;
        @(negedge clk);
        dv = 1; da = 64'h80000030; iv = 1; ia = 64'h180000000;
        @(negedge clk);
        if (!ir || !dr || idata !== 0 || ddata !== 0) $fatal(1, "unmapped address aliases ROM");
        $display("PASS: dual ROM reads, ignored stores, bounds, reset");
        $finish;
    end
    initial begin #10000; $fatal(1, "timeout"); end
endmodule
