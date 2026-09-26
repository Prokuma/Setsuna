# Frequencies from the pinned Gowin_rPLL: 27 * (58+1)/(3+1), divided by 4.
# These names are present in the flattened Yosys netlist.
# Board-level DDR setup/hold and source-synchronous capture still need validation.
create_clock -name reference -period 37.037037 [get_nets {ddr_boot.physical_memory.clk27}]
create_clock -name ddr_fast -period 2.510986 [get_nets {ddr_boot.physical_memory.hardware_phy.fast_clk}]
create_clock -name ddr_phase -period 2.510986 [get_nets {ddr_boot.physical_memory.ddr_ck}]
create_clock -name system -period 10.043942 [get_nets {ddr_boot.memory.adapter.clk}]
