create_clock -name reference -period 37.037037 [get_ports {clk}]
create_clock -name ddr -period 9.259259 [get_nets {ddr_boot.command_bridge.controller_clk}]
