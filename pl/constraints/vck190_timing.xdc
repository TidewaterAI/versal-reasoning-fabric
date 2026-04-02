# vck190_timing.xdc — Timing constraints for Versal VCK190 reasoning fabric.
#
# The PL clock is provided by CIPS (pl_clk0). The actual frequency is
# configured in the block design; this file constrains the fabric logic.

# PL fabric clock (250 MHz from CIPS)
# The actual clock is created by the block design; this is a reference.
# Uncomment and adjust if using a standalone (non-BD) flow:
# create_clock -period 4.000 -name clk_pl [get_ports clk_pl]

# PPS input (asynchronous external reference)
set_false_path -from [get_ports pps_in]

# External kill switch (asynchronous, 2-FF synchronized in safety_supervisor)
set_false_path -from [get_ports kill_ext]

# Lane enable and mode control (quasi-static, changed by PS software)
set_false_path -from [get_ports lane_enable*]
set_false_path -from [get_ports lane_mode_bicky*]

# AIE PLIO interfaces use dedicated CDC — no PL-side timing constraints needed.
# The aiecompiler handles PLIO timing automatically.

# Instrument inputs (if directly connected to FMC+ pins)
# These will need proper IODELAYCTRL and IDELAY constraints when the
# instrument_bridge module is implemented. Placeholder:
# set_false_path -from [get_ports instr_*]
