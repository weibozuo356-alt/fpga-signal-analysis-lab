# ============================================================
# 100 MHz board clock
# ============================================================
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports clk_in]
create_clock -name sys_clk -period 10.000 [get_ports clk_in]


# ============================================================
# DDS frequency-selection switches
#
# freq_sel[2:0]:
# 000 -> 1 kHz
# 001 -> 10 kHz
# 010 -> 50 kHz
# 011 -> 1 MHz
# 100 -> 1.5 MHz
# 101 -> 2 MHz
# 110 -> default 1 kHz
# 111 -> default 1 kHz
# ============================================================
set_property -dict {PACKAGE_PIN R1 IOSTANDARD LVCMOS33} [get_ports {freq_sel[0]}]
set_property -dict {PACKAGE_PIN N4 IOSTANDARD LVCMOS33} [get_ports {freq_sel[1]}]
set_property -dict {PACKAGE_PIN M4 IOSTANDARD LVCMOS33} [get_ports {freq_sel[2]}]


# ============================================================
# External AD/DA board: DAC clock
#
# Teacher EGo1.xdc:
#   clk_da -> B16
#
# ADDA schematic:
#   P1 pin 1 -> DACLK
# ============================================================
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports dac_clk]


# ============================================================
# External AD/DA board: 14-bit DAC data
#
# dac_data[13] -> DADB13, most-significant bit
# dac_data[0]  -> DADB0,  least-significant bit
#
# The upper eight bits correspond to sin_out[7:0]
# in the teacher-provided EGo1.xdc.
# ============================================================
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33} [get_ports {dac_data[13]}]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports {dac_data[12]}]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports {dac_data[11]}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports {dac_data[10]}]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports {dac_data[9]}]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports {dac_data[8]}]
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports {dac_data[7]}]
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports {dac_data[6]}]


# ============================================================
# External AD/DA board: lower six DAC data bits
#
# These correspond to exp_io[20], exp_io[5], exp_io[21],
# exp_io[6], exp_io[22], exp_io[7] in the teacher XDC.
# ============================================================
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {dac_data[5]}]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports {dac_data[4]}]
set_property -dict {PACKAGE_PIN B14 IOSTANDARD LVCMOS33} [get_ports {dac_data[3]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {dac_data[2]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports {dac_data[1]}]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports {dac_data[0]}]


# ============================================================
# Seven-segment digit enables: active high
# ============================================================
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[0]}]
set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[1]}]
set_property -dict {PACKAGE_PIN C1 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[2]}]
set_property -dict {PACKAGE_PIN H1 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[3]}]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[4]}]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[5]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[6]}]
set_property -dict {PACKAGE_PIN G6 IOSTANDARD LVCMOS33} [get_ports {seg_cs_pin[7]}]


# ============================================================
# Seven-segment data group 0
# Bit order: a, b, c, d, e, f, g, dp
# ============================================================
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[0]}]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[1]}]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[2]}]
set_property -dict {PACKAGE_PIN B1 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[3]}]
set_property -dict {PACKAGE_PIN A1 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[4]}]
set_property -dict {PACKAGE_PIN B3 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[5]}]
set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[6]}]
set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {seg_data_0_pin[7]}]


# ============================================================
# Seven-segment data group 1
# Bit order: a, b, c, d, e, f, g, dp
# ============================================================
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[0]}]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[1]}]
set_property -dict {PACKAGE_PIN D3 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[2]}]
set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[3]}]
set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[4]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[5]}]
set_property -dict {PACKAGE_PIN D2 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[6]}]
set_property -dict {PACKAGE_PIN H2 IOSTANDARD LVCMOS33} [get_ports {seg_data_1_pin[7]}]

# ============================================================
# External AD/DA board: ADC sampling clock
#
# Teacher EGo1.xdc:
#   clk_ad -> H17
#
# FPGA outputs the 50 MHz sampling clock to the external ADC.
# ============================================================
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports clk_ad]


# ============================================================
# External AD/DA board: 10-bit ADC data
#
# Teacher EGo1.xdc:
#   ad_in[9:0] use the following FPGA package pins.
#
# ADC output format:
#   ad_in[9] -> most-significant bit
#   ad_in[0] -> least-significant bit
# ============================================================
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports {ad_in[0]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {ad_in[1]}]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports {ad_in[2]}]
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports {ad_in[3]}]
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {ad_in[4]}]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {ad_in[5]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {ad_in[6]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {ad_in[7]}]
set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports {ad_in[8]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {ad_in[9]}]


# ============================================================
# External AD/DA board: ADC clamp control
#
# AD/DA board schematic:
#   Expansion-header pin 16 -> CLAMP
#
# Teacher EGo1.xdc:
#   Expansion-header pin 16 corresponds to exp_io[23]
#   exp_io[23] -> FPGA package pin A11
#
# The Verilog top-level port is renamed adc_clamp.
# ============================================================
set_property -dict {PACKAGE_PIN A11 IOSTANDARD LVCMOS33} [get_ports adc_clamp]
# ============================================================
# Display-selection switches (physical silk-screen labels)
#
# Switch 4 = 0:
#   display student ID 20051121
#
# Switch 4 = 1, switch 3 = 0:
#   display measured frequency in Hz
#
# Switch 4 = 1, switch 3 = 1:
#   display THD percentage
# ============================================================
set_property -dict {PACKAGE_PIN P2 IOSTANDARD LVCMOS33} [get_ports display_mode]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports thd_display_select]
