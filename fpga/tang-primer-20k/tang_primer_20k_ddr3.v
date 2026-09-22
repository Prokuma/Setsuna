`timescale 1ns/1ps
// Tang Primer 20K DDR3 PHY wrapper. Simulation substitutes a transaction
// model at the same 16-bit command boundary used by the real controller.
module tang_primer_20k_ddr3 #(
    parameter integer SIMULATION = 0
) (
    input  wire        clk27,
    input  wire        reset,
    output wire        system_clk,
    output wire        init_done,
    input  wire        read_command,
    input  wire        write_command,
    input  wire        refresh_command,
    input  wire [25:0] address,
    input  wire [15:0] write_data,
    output wire [15:0] read_data,
    output wire        data_ready,
    output wire        busy,
    inout  wire [15:0] ddr_dq,
    inout  wire [1:0]  ddr_dqs,
    output wire [12:0] ddr_addr,
    output wire [2:0]  ddr_bank,
    output wire        ddr_cs_n,
    output wire        ddr_ras_n,
    output wire        ddr_cas_n,
    output wire        ddr_we_n,
    output wire        ddr_ck,
    output wire        ddr_cke,
    output wire        ddr_odt,
    output wire        ddr_reset_n,
    output wire [1:0]  ddr_dm
);
    generate
        if (SIMULATION) begin : simulation_phy
            wire model_init_done;
            assign system_clk = clk27;
            assign init_done = model_init_done;
            assign ddr_dq = 16'bz;
            assign ddr_dqs = 2'bz;
            assign ddr_addr = 0;
            assign ddr_bank = 0;
            assign ddr_cs_n = 1'b1;
            assign ddr_ras_n = 1'b1;
            assign ddr_cas_n = 1'b1;
            assign ddr_we_n = 1'b1;
            assign ddr_ck = 1'b0;
            assign ddr_cke = 1'b0;
            assign ddr_odt = 1'b0;
            assign ddr_reset_n = 1'b0;
            assign ddr_dm = 2'b11;

            ddr3_controller_model model (
                .clk(clk27), .reset(reset), .read_command(read_command),
                .write_command(write_command), .refresh_command(refresh_command),
                .address(address), .write_data(write_data), .read_data(read_data),
                .data_ready(data_ready), .busy(busy), .init_done(model_init_done)
            );
        end else begin : hardware_phy
            wire fast_clk;
            wire memory_clk;
            wire pll_lock;
            wire controller_busy;
            wire write_level_done;
            wire read_calib_done;
            wire [127:0] unused_read_burst;
            wire [7:0] unused_write_step;
            wire [1:0] unused_read_position;
            wire [2:0] unused_read_select;
            wire [63:0] unused_debug;
            reg initialized = 1'b0;

            Gowin_rPLL pll (
                .clkout(fast_clk), .clkoutp(memory_clk), .lock(pll_lock),
                .clkoutd(system_clk), .clkin(clk27)
            );

            always @(posedge system_clk) begin
                if (reset || !pll_lock)
                    initialized <= 1'b0;
                else if (!controller_busy && write_level_done && read_calib_done)
                    initialized <= 1'b1;
            end

            assign init_done = initialized;
            assign busy = controller_busy;

            ddr3_controller #(.ROW_WIDTH(13), .COL_WIDTH(10), .BANK_WIDTH(3)) controller (
                .pclk(system_clk), .fclk(fast_clk), .ck(memory_clk),
                .resetn(!reset && pll_lock), .rd(read_command), .wr(write_command),
                .refresh(refresh_command), .addr(address), .din(write_data),
                .dout(read_data), .dout128(unused_read_burst),
                .data_ready(data_ready), .busy(controller_busy),
                .write_level_done(write_level_done), .wstep(unused_write_step),
                .read_calib_done(read_calib_done), .rclkpos(unused_read_position),
                .rclksel(unused_read_select), .debug(unused_debug),
                .DDR3_DQ(ddr_dq), .DDR3_DQS(ddr_dqs), .DDR3_A(ddr_addr),
                .DDR3_BA(ddr_bank), .DDR3_nRAS(ddr_ras_n), .DDR3_nCAS(ddr_cas_n),
                .DDR3_nWE(ddr_we_n), .DDR3_nCS(ddr_cs_n), .DDR3_CK(ddr_ck),
                .DDR3_CKE(ddr_cke), .DDR3_nRESET(ddr_reset_n),
                .DDR3_DM(ddr_dm), .DDR3_ODT(ddr_odt)
            );
        end
    endgenerate
endmodule
