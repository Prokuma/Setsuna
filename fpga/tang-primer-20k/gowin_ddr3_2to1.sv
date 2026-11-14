// SPDX-License-Identifier: Apache-2.0
// Wiring adapted from e-karge/gowin-ddr3, examples/tang-primer-20k-2to1/top.sv.
`include "ddr3/ddr3_ctrl.sv"
`include "ddr3/clk/ddr3_clk_2to1_tang_primer_20k.sv"
`include "ddr3/ddr3_phy_2to1.sv"

module setsuna_gowin_ddr3_2to1 (
    input wire clk27, board_reset,
    output wire system_clk, init_done, calibration_failed,
    input wire read_command, write_command, refresh_command,
    input wire [25:0] address,
    input wire [15:0] write_data,
    output wire [15:0] read_data,
    output wire data_ready, busy,
    output wire ddr_ck, ddr_ck_n, ddr_reset_n, ddr_cke, ddr_cs_n,
    output wire ddr_ras_n, ddr_cas_n, ddr_we_n, ddr_odt,
    output wire [2:0] ddr_bank,
    output wire [13:0] ddr_addr,
    output wire [1:0] ddr_dm,
    inout wire [1:0] ddr_dqs, ddr_dqs_n,
    inout wire [15:0] ddr_dq
);
localparam DQ_W = 16, ROW_W = 13, COL_W = 10, BA_W = 3, DW = 6;
localparam ADDR_W = BA_W + ROW_W + COL_W, LANES = DQ_W / 8;
localparam SYS_FREQ = 108_000_000;
localparam TCK_PS = 1_000_000_000 / (SYS_FREQ / 1000);

wire sys_clk, lock;
assign system_clk = sys_clk;
// the Gowin simulation models of the IO logic refer to GSR
GSR GSR(.GSRI(1'b1));
ddr3_clk_2to1_tang_primer_20k clocks(.clkin(clk27), .clk(sys_clk), .lock(lock));

reg [7:0] reset_cnt;
initial reset_cnt = 0;
wire reset = board_reset || !reset_cnt[7];
always @(posedge sys_clk) begin
    if (board_reset || !lock) reset_cnt <= 0;
    else if (reset) reset_cnt <= reset_cnt + 1'd1;
end

wire calib_done, calib_fail;
assign init_done = calib_done && !calib_fail && lock && !reset;
assign calibration_failed = calib_fail && !reset;

wire ce, phy_reset_n, phy_cke, phy_odt, phy_wr, phy_rd, phy_rvalid, phy_ready;
wire [2:0] phy_cmd;
wire [ROW_W-1:0] phy_addr;
wire [BA_W-1:0] phy_ba;
wire [1:0] phy_wr_ph, phy_rd_ph, phy_wr_shift;
wire [8*DQ_W-1:0] phy_wdata, phy_rdata;
wire [DQ_W-1:0] phy_wmask;
wire [LANES*DW-1:0] phy_rd_delay;

ddr3_ctrl #(
    .DQ_W(DQ_W), .ROW_W(ROW_W), .COL_W(COL_W), .BA_W(BA_W),
    .NPH(1), .TCK_PS(TCK_PS), .CL(6), .CWL(6), .NWR(5), .DLL_OFF(1),
    .T_RFC_PS(110_000), .CAL_DW(DW), .CAL_STEPS(2 ** DW), .CAL_PER_LANE(1)
) ctrl (
    .clk(sys_clk), .ce(ce), .rst(reset),
    .rd(read_command), .wr(write_command), .refresh(refresh_command),
    .addr(address), .din(write_data), .be(2'b11),
    .dout(read_data), .dout_burst(), .data_ready(data_ready), .busy(busy),
    .init_done(), .calib_done(calib_done), .calib_fail(calib_fail),
    .phy_reset_n(phy_reset_n), .phy_cke(phy_cke), .phy_odt(phy_odt),
    .phy_cmd(phy_cmd), .phy_addr(phy_addr), .phy_ba(phy_ba),
    .phy_wr(phy_wr), .phy_wr_ph(phy_wr_ph), .phy_wdata(phy_wdata), .phy_wmask(phy_wmask),
    .phy_rd(phy_rd), .phy_rd_ph(phy_rd_ph), .phy_rd_delay(phy_rd_delay), .phy_wr_shift(phy_wr_shift),
    .phy_rvalid(phy_rvalid), .phy_rdata(phy_rdata), .phy_ready(phy_ready)
);

// the 1Gb chip has 13 row bits, A13 stays low
wire [ROW_W-1:0] ddr_row_addr;
assign ddr_addr = 14'(ddr_row_addr);

ddr3_phy_2to1 #(.DQ_W(DQ_W), .ROW_W(ROW_W), .BA_W(BA_W), .TCK_PS(TCK_PS), .DW(DW)) phy (
    .clk(sys_clk), .lock(lock), .ce(ce), .dbg_rx(),
    .phy_reset_n(phy_reset_n), .phy_cke(phy_cke), .phy_odt(phy_odt),
    .phy_cmd(phy_cmd), .phy_addr(phy_addr), .phy_ba(phy_ba),
    .phy_wr(phy_wr), .phy_wr_ph(phy_wr_ph), .phy_wdata(phy_wdata), .phy_wmask(phy_wmask),
    .phy_rd(phy_rd), .phy_rd_ph(phy_rd_ph), .phy_rd_delay(phy_rd_delay), .phy_wr_shift(phy_wr_shift),
    .phy_rvalid(phy_rvalid), .phy_rdata(phy_rdata), .phy_ready(phy_ready),
    .ddr_ck(ddr_ck), .ddr_ck_n(ddr_ck_n), .ddr_reset_n(ddr_reset_n), .ddr_cke(ddr_cke),
    .ddr_cs_n(ddr_cs_n), .ddr_ras_n(ddr_ras_n), .ddr_cas_n(ddr_cas_n), .ddr_we_n(ddr_we_n),
    .ddr_odt(ddr_odt), .ddr_ba(ddr_bank), .ddr_addr(ddr_row_addr), .ddr_dm(ddr_dm),
    .ddr_dqs(ddr_dqs), .ddr_dqs_n(ddr_dqs_n), .ddr_dq(ddr_dq)
);

endmodule
