# create_project.tcl — Versal VCK190 reasoning fabric (Vivado 2023.2+)
#
# Creates a Vivado project targeting XCVC1902 with:
#   - CIPS (Versal PS: A72 + R5F + NoC)
#   - PL reasoning fabric (versal_top + lane tiles + stream fabric)
#   - AIE graph integration placeholder (Phase 3)
#
# Usage:
#   vivado -mode batch -source scripts/create_project.tcl
#
# Or from Vivado TCL console:
#   source scripts/create_project.tcl

# --- Paths
set script_dir [file dirname [file normalize [info script]]]
set versal_dir [file dirname $script_dir]
set pl_dir     [file join $versal_dir pl]
set proj_name  versal_reasoning_fabric
set proj_dir   [file join $versal_dir vivado_proj]

# Zybo hub sources (shared RTL that transfers directly)
cd $versal_dir

# --- Create project
create_project $proj_name $proj_dir -part xcvc1902-vsva2197-2MP-e-S -force

# Use VCK190 board part if available
set vck_bp [lindex [get_board_parts -quiet -latest_file_version *vck190*] 0]
if {$vck_bp ne ""} {
    set_property board_part $vck_bp [current_project]
    puts "INFO: Using VCK190 board part: $vck_bp"
} else {
    puts "WARN: VCK190 board part not found; continuing with device only."
}

set_property target_language Verilog [current_project]

# --- Add all PL sources (self-contained, no external path dependencies)
# Top-level and lane architecture
add_files [file join $pl_dir src versal_config.svh]
add_files [file join $pl_dir src versal_top.sv]
add_files [file join $pl_dir src lane_tile.sv]
add_files [file join $pl_dir src embedding_projector.sv]
add_files [file join $pl_dir src instrument_bridge.sv]

# Stream routing fabric
add_files [file join $pl_dir src fabric versal_stream_fabric.sv]
add_files [file join $pl_dir src fabric stream_router.sv]

# Safety chain
add_files [file join $pl_dir src safety safety_supervisor.v]
add_files [file join $pl_dir src safety safety_kernel.sv]
add_files [file join $pl_dir src safety cbf_solver.sv]

# Compute cores (Phase 1: PL-local inference)
add_files [file join $pl_dir src compute rc_core.sv]
add_files [file join $pl_dir src compute bicky_inference.sv]

# Plugin interface
add_files [file join $pl_dir src plugins modality_plugin_if.sv]

# Common IP
add_files [file join $pl_dir src common timestamp_counter.v]
add_files [file join $pl_dir src common crypto_signer.sv]

# --- Add constraints
if {[file exists [file join $pl_dir constraints vck190_timing.xdc]]} {
    add_files -fileset constrs_1 [file join $pl_dir constraints vck190_timing.xdc]
}

# --- Set top module
set_property top versal_top [current_fileset]

# --- Create block design with CIPS
create_bd_design "versal_bd"

# Add Versal CIPS (PS)
set cips [create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips cips_0]

# Configure CIPS for basic A72 + NoC
# (Detailed configuration depends on Vivado version; this enables PS and NoC)
set_property -dict [list \
    CONFIG.PS_PMC_CONFIG { \
        PS_NUM_FABRIC_RESETS 1 \
        PS_USE_PMCPL_CLK0 1 \
        PS_BOARD_INTERFACE Custom \
    } \
] $cips

# Add NoC for DDR4 memory controller
set noc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc noc_0]

# Add AXI-Stream DMA for PL data movement
set dma_mm2s [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_mm2s_burst_size {256} \
    CONFIG.c_s2mm_burst_size {256} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {64} \
    CONFIG.c_m_axi_s2mm_data_width {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {64} \
] $dma_mm2s

# Save and validate
save_bd_design
puts "INFO: Block design created. Manual wiring required in Vivado GUI."
puts "INFO: Connect CIPS pl_clk0 -> versal_top clk_pl"
puts "INFO: Connect DMA M_AXIS_MM2S -> versal_top mm2s_*"
puts "INFO: Connect versal_top s2mm_* -> DMA S_AXIS_S2MM"

# --- Synthesis settings
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

puts "INFO: Project created at $proj_dir"
puts "INFO: Target: XCVC1902-vsva2197-2MP-e-S (VCK190)"
puts "INFO: Phase 1 (PL-only, USE_AIE=0): ready for synthesis."
puts "INFO: Run 'launch_runs synth_1' to synthesize."
