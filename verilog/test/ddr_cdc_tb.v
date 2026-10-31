`timescale 1ns/1ps
module ddr_cdc_tb;
    reg source_clk = 0, controller_clk = 0, reset = 1;
    integer source_half = 5, controller_half = 2;
    always #(source_half) source_clk = ~source_clk;
    always #(controller_half) controller_clk = ~controller_clk;
    reg rd = 0, wr = 0, refresh = 0;
    reg [25:0] address = 0;
    reg [15:0] write_data = 0;
    wire initialized, busy, ready;
    wire [15:0] read_data;
    wire phy_rd, phy_wr, phy_refresh;
    wire [25:0] phy_address;
    wire [15:0] phy_write_data;
    reg phy_init = 0, phy_busy = 1, phy_ready = 0;
    reg [15:0] phy_read_data = 0;
    reg [15:0] memory [0:31];
    reg pending_read = 0;
    reg [4:0] saved_address;
    integer ticks = 0, init_ticks = 0;
    integer writes = 0, reads = 0, refreshes = 0, i;
    ddr3_command_cdc dut (
        .source_clk(source_clk), .controller_clk(controller_clk), .reset(reset),
        .source_read(rd), .source_write(wr), .source_refresh(refresh),
        .source_address(address), .source_write_data(write_data),
        .source_init_done(initialized), .source_busy(busy),
        .source_data_ready(ready), .source_read_data(read_data),
        .controller_init_done(phy_init), .controller_busy(phy_busy),
        .controller_data_ready(phy_ready), .controller_read_data(phy_read_data),
        .controller_read(phy_rd), .controller_write(phy_wr),
        .controller_refresh(phy_refresh), .controller_address(phy_address),
        .controller_write_data(phy_write_data)
    );
    always @(posedge controller_clk) begin
        phy_ready <= 0;
        if (reset) begin
            phy_init <= 0; phy_busy <= 1; ticks <= 0; init_ticks <= 0;
            pending_read <= 0;
            writes <= 0; reads <= 0; refreshes <= 0;
        end else if (!phy_init) begin
            if (init_ticks == 3) begin phy_init <= 1; phy_busy <= 0; end
            else init_ticks <= init_ticks + 1;
        end else if (!phy_busy && (phy_rd || phy_wr || phy_refresh)) begin
            if ((phy_rd + {1'b0, phy_wr} + {1'b0, phy_refresh}) != 1)
                $fatal(1, "CDC forwarded conflicting commands");
            phy_busy <= 1; ticks <= 5;
            pending_read <= phy_rd;
            saved_address <= phy_address[4:0];
            if (phy_wr) begin memory[phy_address[4:0]] <= phy_write_data; writes <= writes + 1; end
            if (phy_rd) reads <= reads + 1;
            if (phy_refresh) refreshes <= refreshes + 1;
        end else if (phy_busy && ticks != 0) begin
            ticks <= ticks - 1;
            // Read data precedes busy release; the bridge must retain it.
            if (ticks == 3 && pending_read) begin
                phy_ready <= 1;
                phy_read_data <= memory[saved_address];
            end
            if (ticks == 1) phy_busy <= 0;
        end
    end

    task transfer(input [2:0] command, input [25:0] a, input [15:0] value);
        begin
            @(negedge source_clk);
            while (busy) @(negedge source_clk);
            {rd, wr, refresh} = command; address = a; write_data = value;
            @(negedge source_clk);
            {rd, wr, refresh} = 0; address = 26'h3ffffff; write_data = ~value;
            if (!busy) $fatal(1, "CDC did not accept command");
            while (busy) @(negedge source_clk);
            if (command[2]) begin
                if (!ready || read_data !== value) $fatal(1, "CDC lost read: %h != %h", read_data, value);
            end else if (ready) $fatal(1, "non-read generated data_ready");
            @(negedge source_clk);
            if (ready) $fatal(1, "data_ready repeated");
        end
    endtask

    initial begin
        for (i = 0; i < 32; i = i + 1) memory[i] = 0;
        repeat (5) @(negedge source_clk);
        reset = 0;
        wait (initialized);
        for (i = 0; i < 16; i = i + 1) begin
            transfer(3'b010, i, 16'hcafe ^ i);
            transfer(3'b100, i, 16'hcafe ^ i);
        end
        transfer(3'b001, 0, 0);
        source_half = 2; controller_half = 7;
        for (i = 16; i < 32; i = i + 1) begin
            transfer(3'b010, i, 16'hbeef ^ i);
            transfer(3'b100, i, 16'hbeef ^ i);
        end
        transfer(3'b001, 0, 0);
        if (writes != 32 || reads != 32 || refreshes != 2)
            $fatal(1, "CDC duplicated/lost commands: %0d %0d %0d", writes, reads, refreshes);
        // Reset both domains during an outstanding transfer, then restart.
        @(negedge source_clk); wr = 1; address = 4; write_data = 16'h1234;
        @(negedge source_clk); wr = 0; reset = 1;
        repeat (12) @(negedge source_clk);
        reset = 0;
        wait (initialized);
        transfer(3'b010, 3, 16'habcd);
        transfer(3'b100, 3, 16'habcd);
        if (writes != 1 || reads != 1) $fatal(1, "stale command after reset");
        $display("PASS: DDR command CDC, both clock ratios, held payloads, early read data, refresh, reset");
        $finish;
    end
    initial begin #1000000; $fatal(1, "DDR CDC timeout"); end
endmodule
