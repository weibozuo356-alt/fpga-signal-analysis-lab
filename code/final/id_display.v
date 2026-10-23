`timescale 1ns / 1ps

module id_display #(
    parameter integer SCAN_CYCLES = 50_000
)(
    input  wire        clk_in,
    input  wire [2:0]  freq_sel,
    input  wire        display_mode,
    input  wire        thd_display_select,

    // External 14-bit DAC interface
    output wire        dac_clk,
    output wire [13:0] dac_data,

    // External 10-bit ADC interface
    input  wire [9:0]  ad_in,
    output wire        clk_ad,
    output wire        adc_clamp,

    // Eight-digit seven-segment display
    output reg  [7:0]  seg_cs_pin,
    output reg  [7:0]  seg_data_0_pin,
    output reg  [7:0]  seg_data_1_pin
);


    // ============================================================
    // 100 MHz -> 10 MHz and 50 MHz clocks
    // ============================================================
    wire clk_10m;
    wire clk_50m;
    wire clk_10m_locked;

    clk_wiz_10m u_clk_wiz_10m (
        .clk_out1 (clk_10m),
        .clk_out2 (clk_50m),
        .reset    (1'b0),
        .locked   (clk_10m_locked),
        .clk_in1  (clk_in)
    );


    // ============================================================
    // ADC control
    //
    // A low level disables the ADC clamp function.
    // ============================================================
    assign adc_clamp = 1'b0;


    // ============================================================
    // Forwarded 50 MHz ADC sampling clock
    // ============================================================
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_adc_clk_oddr (
        .Q  (clk_ad),
        .C  (clk_50m),
        .CE (clk_10m_locked),
        .D1 (1'b1),
        .D2 (1'b0),
        .R  (1'b0),
        .S  (1'b0)
    );


    // ============================================================
    // DDS frequency-control words
    //
    // K = round(f_out * 2^32 / 10 MHz)
    // ============================================================
    localparam [31:0] K_1KHZ   = 32'd429497;
    localparam [31:0] K_10KHZ  = 32'd4294967;
    localparam [31:0] K_50KHZ  = 32'd21474836;
    localparam [31:0] K_1MHZ   = 32'd429496730;
    localparam [31:0] K_1P5MHZ = 32'd644245094;
    localparam [31:0] K_2MHZ   = 32'd858993459;


    function [31:0] select_frequency_word;
        input [2:0] select;

        begin
            case (select)
                3'b000: select_frequency_word = K_1KHZ;
                3'b001: select_frequency_word = K_10KHZ;
                3'b010: select_frequency_word = K_50KHZ;
                3'b011: select_frequency_word = K_1MHZ;
                3'b100: select_frequency_word = K_1P5MHZ;
                3'b101: select_frequency_word = K_2MHZ;

                // 110 and 111 default to 1 kHz.
                default: select_frequency_word = K_1KHZ;
            endcase
        end
    endfunction


    // ============================================================
    // Synchronize frequency switches into the 10 MHz DDS domain
    // ============================================================
    reg [2:0] freq_sel_meta = 3'b000;
    reg [2:0] freq_sel_sync = 3'b000;
    reg [2:0] freq_sel_last = 3'b000;

    reg        dds_config_sent  = 1'b0;
    reg [31:0] dds_config_data  = K_1KHZ;
    reg        dds_config_valid = 1'b0;

    always @(posedge clk_10m) begin
        freq_sel_meta <= freq_sel;
        freq_sel_sync <= freq_sel_meta;

        dds_config_valid <= 1'b0;

        if (!clk_10m_locked) begin
            dds_config_sent <= 1'b0;
        end 
        else if (!dds_config_sent ||
                     (freq_sel_sync != freq_sel_last)) begin

            freq_sel_last    <= freq_sel_sync;
            dds_config_data  <=
                select_frequency_word(freq_sel_sync);
            dds_config_valid <= 1'b1;
            dds_config_sent  <= 1'b1;
        end
    end


    // ============================================================
    // DDS Compiler±àÒëÆ÷
    // ============================================================
    wire               dds_valid;
    wire signed [15:0] dds_data;

    dds_sine u_dds_sine (
        .aclk                 (clk_10m),
        .s_axis_config_tvalid (dds_config_valid),      
        .s_axis_config_tdata  (dds_config_data),
        .m_axis_data_tvalid   (dds_valid),
        .m_axis_data_tdata    (dds_data)
    );


    // ============================================================
    // DDS signed data -> DAC unsigned offset-binary data
    // ============================================================
    reg [13:0] dac_data_reg = 14'h2000;

    always @(posedge clk_10m) begin
        if (!clk_10m_locked) begin
            dac_data_reg <= 14'h2000;
        end
         else if (dds_valid) begin
            dac_data_reg <= { ~dds_data[15], dds_data[14:2] };
        end
    end

    assign dac_data = dac_data_reg;


    // ============================================================
    // Forwarded 10 MHz DAC clock
    //
    // DAC data changes at the rising edge of clk_10m.
    // dac_clk rises 50 ns later, at the falling edge.
    // ============================================================
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_dac_clk_oddr (
        .Q  (dac_clk),
        .C  (clk_10m),
        .CE (1'b1),
        .D1 (1'b0),
        .D2 (1'b1),
        .R  (1'b0),
        .S  (1'b0)
    );


    // ============================================================
    // Capture the external 10-bit ADC output
    // ============================================================
    reg [9:0] adc_sample = 10'd0;

    always @(posedge clk_50m) begin
        if (!clk_10m_locked) begin
            adc_sample <= 10'd0;
        end else begin
            adc_sample <= ad_in;
        end
    end


    // ============================================================
    // Automatic ADC calibration and frequency measurement
    //
    // After power-up or a frequency-selection change:
    //
    // 1. Wait 1 ms for the analog signal to settle.
    // 2. Record ADC minimum and maximum for 10 ms.
    // 3. Calculate midpoint and hysteresis thresholds.
    // 4. Generate one rising pulse per waveform period.
    // 5. Count waveform periods for 2 seconds.
    // ============================================================

    // 50 MHz * 1 ms = 50,000
    localparam integer ADC_SETTLE_CYCLES = 50_000;

    // 50 MHz * 10 ms = 500,000
    localparam integer ADC_CALIBRATION_CYCLES = 500_000;

    // 50 MHz * 2 s = 100,000,000
    localparam integer FREQUENCY_GATE_CYCLES = 100_000_000;


    // Synchronize the switches into the 50 MHz ADC domain.
    reg [2:0] freq_sel_50m_meta = 3'b000;
    reg [2:0] freq_sel_50m_sync = 3'b000;
    reg [2:0] freq_sel_50m_last = 3'b000;


    // Calibration registers.
    reg [15:0] adc_settle_count      = 16'd0;
    reg [18:0] adc_calibration_count = 19'd0;

    reg [9:0] adc_minimum  = 10'd1023;
    reg [9:0] adc_maximum  = 10'd0;
    reg [9:0] adc_midpoint = 10'd512;

    reg [9:0] adc_threshold_low  = 10'd508;
    reg [9:0] adc_threshold_high = 10'd516;

    reg calibration_done = 1'b0;
    
    // Convert the unsigned ADC sample into a signed value
    // centered around zero.
    wire signed [10:0] adc_centered;

    assign adc_centered =
    $signed({1'b0, adc_sample}) -
    $signed({1'b0, adc_midpoint});


    // Crossing detector and frequency counter.
    reg        adc_signal_high      = 1'b0;
    reg        adc_rising_pulse     = 1'b0;
    reg [26:0] frequency_gate_count = 27'd0;
    reg [31:0] waveform_cycle_count = 32'd0;
    reg [31:0] measured_frequency   = 32'd0;
    reg        measurement_update_toggle = 1'b0;


    // Include the current sample in the minimum/maximum result.
    wire [9:0] adc_minimum_next =
        (adc_sample < adc_minimum)
        ? adc_sample
        : adc_minimum;

    wire [9:0] adc_maximum_next =
        (adc_sample > adc_maximum)
        ? adc_sample
        : adc_maximum;

    wire [9:0] adc_range_next =
        adc_maximum_next - adc_minimum_next;

    wire [10:0] adc_sum_next =
        {1'b0, adc_minimum_next} +
        {1'b0, adc_maximum_next};

    wire [9:0] adc_midpoint_next =
        adc_sum_next[10:1];


    // Hysteresis is one eighth of the measured signal range.
    wire [9:0] adc_hysteresis_raw =
        adc_range_next >> 3;

    wire [9:0] adc_hysteresis_next =
        (adc_hysteresis_raw < 10'd4)
        ? 10'd4
        : adc_hysteresis_raw;


    // One rising crossing per analog waveform period.
    wire adc_rising_crossing_now =
        calibration_done &&
        !adc_signal_high &&
        (adc_sample >= adc_threshold_high);


    always @(posedge clk_50m) begin
        // Synchronize the asynchronous switches.
        freq_sel_50m_meta <= freq_sel;
        freq_sel_50m_sync <= freq_sel_50m_meta;

        // This debug pulse normally remains low.
        adc_rising_pulse <= 1'b0;

        if (!clk_10m_locked) begin
            freq_sel_50m_last <= 3'b000;

            adc_settle_count      <= 16'd0;
            adc_calibration_count <= 19'd0;

            adc_minimum  <= 10'd1023;
            adc_maximum  <= 10'd0;
            adc_midpoint <= 10'd512;

            adc_threshold_low  <= 10'd508;
            adc_threshold_high <= 10'd516;

            calibration_done <= 1'b0;
            adc_signal_high  <= 1'b0;

            frequency_gate_count <= 27'd0;
            waveform_cycle_count <= 32'd0;
            measured_frequency   <= 32'd0;
            measurement_update_toggle <= 1'b0;

        end else if (freq_sel_50m_sync !=
                     freq_sel_50m_last) begin
            // Restart calibration after changing frequency.
            freq_sel_50m_last <= freq_sel_50m_sync;

            adc_settle_count      <= 16'd0;
            adc_calibration_count <= 19'd0;

            adc_minimum <= 10'd1023;
            adc_maximum <= 10'd0;

            calibration_done <= 1'b0;
            adc_signal_high  <= 1'b0;

            frequency_gate_count <= 27'd0;
            waveform_cycle_count <= 32'd0;
            measured_frequency   <= 32'd0;

            // Tell the display domain to show zero while the
            // newly selected frequency is being measured.
            measurement_update_toggle <=
                ~measurement_update_toggle;

        end else if (adc_settle_count <
                     ADC_SETTLE_CYCLES - 1) begin
            // Wait 1 ms for the new analog waveform to settle.
            adc_settle_count <=
                adc_settle_count + 16'd1;

            adc_calibration_count <= 19'd0;
            adc_minimum <= 10'd1023;
            adc_maximum <= 10'd0;

            calibration_done <= 1'b0;
            adc_signal_high  <= 1'b0;

            frequency_gate_count <= 27'd0;
            waveform_cycle_count <= 32'd0;

        end else if (!calibration_done) begin
            // Record minimum and maximum for 10 ms.
            adc_minimum <= adc_minimum_next;
            adc_maximum <= adc_maximum_next;

            if (adc_calibration_count ==
                ADC_CALIBRATION_CYCLES - 1) begin

                adc_calibration_count <= 19'd0;

                // Reject a missing or extremely small signal.
                if (adc_range_next >= 10'd32) begin
                    adc_midpoint <= adc_midpoint_next;

                    adc_threshold_low <=
                        adc_midpoint_next -
                        adc_hysteresis_next;

                    adc_threshold_high <=
                        adc_midpoint_next +
                        adc_hysteresis_next;

                    calibration_done <= 1'b1;
                    adc_signal_high  <= 1'b0;

                    frequency_gate_count <= 27'd0;
                    waveform_cycle_count <= 32'd0;
                end else begin
                    // No useful signal: repeat calibration.
                    adc_minimum <= 10'd1023;
                    adc_maximum <= 10'd0;

                    calibration_done <= 1'b0;
                end

            end else begin
                adc_calibration_count <=
                    adc_calibration_count + 19'd1;
            end

        end else begin
            // Schmitt-trigger-style rising crossing detector.
            if (adc_rising_crossing_now) begin
                adc_signal_high  <= 1'b1;
                adc_rising_pulse <= 1'b1;
            end else if (adc_signal_high &&
                         (adc_sample <=
                          adc_threshold_low)) begin
                adc_signal_high <= 1'b0;
            end

            // Two-second measurement gate.
            if (frequency_gate_count ==
                FREQUENCY_GATE_CYCLES - 1) begin

                frequency_gate_count <= 27'd0;

                // Count the final-cycle crossing, add one for
                // rounding, and divide the two-second count by 2.
                measured_frequency <=
                    (waveform_cycle_count +
                     (adc_rising_crossing_now
                      ? 32'd1
                      : 32'd0) +
                     32'd1) >> 1;

                // Toggle once for every new completed result.
                measurement_update_toggle <=
                    ~measurement_update_toggle;

                waveform_cycle_count <= 32'd0;

            end else begin
                frequency_gate_count <=
                    frequency_gate_count + 27'd1;

                if (adc_rising_crossing_now) begin
                    waveform_cycle_count <=
                        waveform_cycle_count + 32'd1;
                end
            end
        end
    end

// ============================================================
// 4096-point FFT input and output
//
// Input:
//   real part      = signed ADC sample centered around zero
//   imaginary part = 0
//
// This version first verifies the raw FFT data path.
// A window function will be added after the FFT is verified.
// ============================================================


// ------------------------------------------------------------
// Frequency-dependent boxcar averaging and decimation
//
// The ADC and FFT IP clocks both remain at 50 MHz.  Only the
// AXI input sample-valid rate is reduced for the low-frequency
// ranges.  This gives the 4096-point FFT enough frequency
// resolution for all six DAC output frequencies.
//
//   freq_sel  measurement mode       average length  effective Fs
//     000        1 kHz           500           100 kHz
//     001       10 kHz            50             1 MHz
//     010       50 kHz            10             5 MHz
//     011        1 MHz             1            50 MHz
//     100      1.5 MHz             1            50 MHz
//     101        2 MHz             1            50 MHz
//     110     auto 10...100 kHz      10             5 MHz
//     111     reserved/default      500           100 kHz
// ------------------------------------------------------------
reg [9:0] decimation_factor;

always @(*) begin
    case (freq_sel_50m_sync)
        3'b000: decimation_factor = 10'd500;
        3'b001: decimation_factor = 10'd50;
        3'b010: decimation_factor = 10'd10;
        3'b011: decimation_factor = 10'd1;
        3'b100: decimation_factor = 10'd1;
        3'b101: decimation_factor = 10'd1;
        3'b110: decimation_factor = 10'd10;
        default: decimation_factor = 10'd500;
    endcase
end


// Eleven signed ADC bits summed 500 times require 21 bits.
reg signed [20:0] decimation_sum = 21'sd0;
reg        [9:0]  decimation_count = 10'd0;

wire signed [20:0] adc_centered_21;
wire signed [20:0] decimation_sum_next;

assign adc_centered_21 = {
    {10{adc_centered[10]}},
    adc_centered
};

assign decimation_sum_next =
    decimation_sum + adc_centered_21;


// Use shifts instead of hardware dividers.  The scale factor is
// common to the fundamental and harmonics, so it cancels in the
// final THD ratio.
reg signed [20:0] decimation_scaled;

always @(*) begin
    case (freq_sel_50m_sync)
        3'b000: decimation_scaled =
            decimation_sum_next >>> 9; // approximately /500

        3'b001: decimation_scaled =
            decimation_sum_next >>> 6; // approximately /50

        3'b010: decimation_scaled =
            decimation_sum_next >>> 4; // approximately /10

        3'b011: decimation_scaled = adc_centered_21;
        3'b100: decimation_scaled = adc_centered_21;
        3'b101: decimation_scaled = adc_centered_21;

        // Automatic 10...100 kHz measurement mode.
        3'b110: decimation_scaled =
            decimation_sum_next >>> 4;

        default: decimation_scaled =
            decimation_sum_next >>> 9;
    endcase
end


wire signed [15:0] decimated_adc_sample;

assign decimated_adc_sample = decimation_scaled[15:0];


// ------------------------------------------------------------
// FFT reset
//
// Keep the FFT in reset until:
// 1. The Clock Wizard is locked.
// 2. ADC calibration has completed.
//
// ARESETn is active low.
// ------------------------------------------------------------
reg [1:0] fft_reset_sync = 2'b00;

always @(posedge clk_50m) begin
    if (!clk_10m_locked) begin
        fft_reset_sync <= 2'b00;
    end else begin
        fft_reset_sync <= {
            fft_reset_sync[0],
            1'b1
        };
    end
end

wire fft_aresetn;

assign fft_aresetn =
    fft_reset_sync[1] &&
    calibration_done;


// ------------------------------------------------------------
// FFT configuration channel
//
// s_axis_config_tdata[0]:
//   1 = forward FFT
//   0 = inverse FFT
// ------------------------------------------------------------
wire [7:0] fft_config_data;

reg  fft_config_valid = 1'b0;
reg  fft_config_done  = 1'b0;
wire fft_config_ready;

assign fft_config_data = 8'b0000_0001;


always @(posedge clk_50m) begin
    if (!fft_aresetn) begin
        fft_config_valid <= 1'b0;
        fft_config_done  <= 1'b0;

    end else if (!fft_config_done) begin
        fft_config_valid <= 1'b1;

        if (fft_config_valid &&
            fft_config_ready) begin

            fft_config_valid <= 1'b0;
            fft_config_done  <= 1'b1;
        end

    end else begin
        fft_config_valid <= 1'b0;
    end
end


// ------------------------------------------------------------
// FFT input AXI-Stream channel
//
// The lower 16 bits contain the real part.
// The upper 16 bits contain the imaginary part, which is zero.
//
// tlast is asserted with every 4096th input sample.
// ------------------------------------------------------------
reg [31:0] fft_input_data  = 32'd0;
reg        fft_input_valid = 1'b0;
reg        fft_input_last  = 1'b0;

wire       fft_input_ready;

reg [11:0] fft_input_index = 12'd0;


// ------------------------------------------------------------
// 4096-point Hann window
//
// hann_4096_q15.mem contains unsigned positive Q1.15
// coefficients from 0 to 32767.  The current FFT input index is
// also the address of the corresponding window coefficient.
//
// An asynchronous ROM read keeps the sample and coefficient
// alignment simple.  Vivado implements this as distributed ROM.
// ------------------------------------------------------------
(* rom_style = "distributed" *)
reg [15:0] hann_rom [0:4095];

initial begin
    $readmemh("hann_4096_q15.mem", hann_rom);
end

wire [15:0] hann_coefficient;
wire signed [31:0] hann_product;
wire signed [31:0] hann_product_scaled;
wire signed [15:0] windowed_adc_sample;

assign hann_coefficient = hann_rom[fft_input_index];

assign hann_product =
    decimated_adc_sample * $signed(hann_coefficient);

assign hann_product_scaled = hann_product >>> 15;

assign windowed_adc_sample = hann_product_scaled[15:0];


always @(posedge clk_50m) begin
    if (!fft_aresetn ||
        !fft_config_done) begin

        decimation_sum   <= 21'sd0;
        decimation_count <= 10'd0;

        fft_input_data  <= 32'd0;
        fft_input_valid <= 1'b0;
        fft_input_last  <= 1'b0;
        fft_input_index <= 12'd0;

    end else begin
        // Remove tvalid after an accepted sample.  A new averaged
        // sample below may set it again in the same clock cycle.
        if (fft_input_valid && fft_input_ready) begin
            fft_input_valid <= 1'b0;
        end

        // Do not overwrite a sample while the FFT is applying
        // back-pressure.  Pipelined Streaming I/O normally keeps
        // tready high, but this also makes the source AXI-safe.
        if (!fft_input_valid || fft_input_ready) begin
            if (decimation_factor == 10'd1) begin
                // The three high-frequency ranges use every ADC
                // sample, with no averaging or decimation.
                decimation_sum   <= 21'sd0;
                decimation_count <= 10'd0;

                fft_input_data <= {
                    16'd0,
                    windowed_adc_sample
                };

                fft_input_valid <= 1'b1;
                fft_input_last  <=
                    (fft_input_index == 12'd4095);

                if (fft_input_index == 12'd4095) begin
                    fft_input_index <= 12'd0;
                end else begin
                    fft_input_index <=
                        fft_input_index + 12'd1;
                end

            end else if (decimation_count ==
                         decimation_factor - 10'd1) begin
                // decimation_sum_next includes the current ADC
                // sample, completing this averaging group.
                decimation_sum   <= 21'sd0;
                decimation_count <= 10'd0;

                fft_input_data <= {
                    16'd0,
                    windowed_adc_sample
                };

                fft_input_valid <= 1'b1;
                fft_input_last  <=
                    (fft_input_index == 12'd4095);

                if (fft_input_index == 12'd4095) begin
                    fft_input_index <= 12'd0;
                end else begin
                    fft_input_index <=
                        fft_input_index + 12'd1;
                end

            end else begin
                // Continue forming the current average.
                decimation_sum <= decimation_sum_next;
                decimation_count <=
                    decimation_count + 10'd1;
            end
        end
    end
end


// ------------------------------------------------------------
// FFT output signals
//
// For the selected unscaled configuration, each component is
// presented in a 32-bit AXI field.
//
// Lower 32 bits: real part
// Upper 32 bits: imaginary part
//
// The low 12 bits of TUSER contain XK_INDEX = 0...4095.
// ------------------------------------------------------------
wire [63:0] fft_output_data;
wire [15:0] fft_output_user;

wire        fft_output_valid;
wire        fft_output_last;

wire signed [31:0] fft_output_real;
wire signed [31:0] fft_output_imag;

wire [11:0] fft_output_index;

assign fft_output_real =
    $signed(fft_output_data[31:0]);

assign fft_output_imag =
    $signed(fft_output_data[63:32]);

assign fft_output_index =
    fft_output_user[11:0];


// FFT diagnostic event signals.
wire fft_event_frame_started;
wire fft_event_tlast_unexpected;
wire fft_event_tlast_missing;
wire fft_event_status_channel_halt;
wire fft_event_data_in_channel_halt;
wire fft_event_data_out_channel_halt;


// ------------------------------------------------------------
// FFT IP instance
// ------------------------------------------------------------
fft_thd u_fft_thd (
    .aclk                           (clk_50m),
    .aresetn                        (fft_aresetn),

    .s_axis_config_tdata            (fft_config_data),
    .s_axis_config_tvalid           (fft_config_valid),
    .s_axis_config_tready           (fft_config_ready),

    .s_axis_data_tdata              (fft_input_data),
    .s_axis_data_tvalid             (fft_input_valid),
    .s_axis_data_tready             (fft_input_ready),
    .s_axis_data_tlast              (fft_input_last),

    .m_axis_data_tdata              (fft_output_data),
    .m_axis_data_tuser              (fft_output_user),
    .m_axis_data_tvalid             (fft_output_valid),
    .m_axis_data_tready             (1'b1),
    .m_axis_data_tlast              (fft_output_last),

    .event_frame_started            (
        fft_event_frame_started
    ),
    .event_tlast_unexpected         (
        fft_event_tlast_unexpected
    ),
    .event_tlast_missing            (
        fft_event_tlast_missing
    ),
    .event_status_channel_halt      (
        fft_event_status_channel_halt
    ),
    .event_data_in_channel_halt     (
        fft_event_data_in_channel_halt
    ),
    .event_data_out_channel_halt    (
        fft_event_data_out_channel_halt
    )
);


// ============================================================
// FFT bin power
//
// P[k] = Re[k]^2 + Im[k]^2
//
// The FFT output components are signed.  Convert each component
// to its unsigned absolute value before squaring it.  The power,
// index, valid and last signals are registered together so that
// they remain aligned by bin.
// ============================================================
wire [31:0] fft_real_abs;
wire [31:0] fft_imag_abs;

assign fft_real_abs =
    fft_output_real[31]
    ? (~fft_output_real + 32'd1)
    : fft_output_real;

assign fft_imag_abs =
    fft_output_imag[31]
    ? (~fft_output_imag + 32'd1)
    : fft_output_imag;

wire [63:0] fft_real_square;
wire [63:0] fft_imag_square;

assign fft_real_square =
    fft_real_abs * fft_real_abs;

assign fft_imag_square =
    fft_imag_abs * fft_imag_abs;

reg [63:0] fft_bin_power   = 64'd0;
reg [11:0] fft_power_index = 12'd0;
reg        fft_power_valid = 1'b0;
reg        fft_power_last  = 1'b0;

always @(posedge clk_50m) begin
    if (!fft_aresetn) begin
        fft_bin_power   <= 64'd0;
        fft_power_index <= 12'd0;
        fft_power_valid <= 1'b0;
        fft_power_last  <= 1'b0;
    end else begin
        fft_power_valid <= fft_output_valid;
        fft_power_last  <= fft_output_last;

        if (fft_output_valid) begin
            fft_bin_power <=
                fft_real_square + fft_imag_square;

            fft_power_index <= fft_output_index;
        end
    end
end


// ============================================================
// Fundamental detection and harmonic power bands
//
// A Hann-windowed sinusoid occupies several nearby FFT bins.
// Therefore each component uses a five-bin band:
// center - 2 through center + 2.
//
// Only the positive-frequency half is accumulated.  The mirrored
// negative-frequency bins contain the same information and are not
// needed in the THD ratio.
//
// Modes 000...101 retain the known fundamental bins used by task 4.
// Mode 110 searches bins 6...84 for the strongest component.  At
// the 5 MSPS effective sample rate this covers 10...100 kHz.  The
// detected bin from one FFT frame is used during the next frame.
// ============================================================
wire thd_auto_mode;
assign thd_auto_mode =
    (freq_sel_50m_sync == 3'b110);

localparam [11:0] AUTO_SEARCH_MIN_BIN = 12'd6;
localparam [11:0] AUTO_SEARCH_MAX_BIN = 12'd84;

reg [63:0] auto_search_peak_power = 64'd0;
reg [11:0] auto_search_peak_bin   = 12'd0;
reg [11:0] detected_fundamental_bin = 12'd0;
reg        detected_fundamental_valid = 1'b0;

wire auto_search_in_range;
assign auto_search_in_range =
    (fft_power_index >= AUTO_SEARCH_MIN_BIN) &&
    (fft_power_index <= AUTO_SEARCH_MAX_BIN);

always @(posedge clk_50m) begin
    if (!fft_aresetn || !thd_auto_mode) begin
        auto_search_peak_power <= 64'd0;
        auto_search_peak_bin   <= 12'd0;
        detected_fundamental_bin <= 12'd0;
        detected_fundamental_valid <= 1'b0;
    end else if (fft_power_valid) begin
        if (fft_power_index == 12'd0) begin
            auto_search_peak_power <= 64'd0;
            auto_search_peak_bin   <= 12'd0;
        end else if (auto_search_in_range &&
                     (fft_bin_power >
                      auto_search_peak_power)) begin
            auto_search_peak_power <= fft_bin_power;
            auto_search_peak_bin   <= fft_power_index;
        end

        if (fft_power_last) begin
            detected_fundamental_bin <=
                auto_search_peak_bin;

            detected_fundamental_valid <=
                (auto_search_peak_power != 64'd0);
        end
    end
end


reg [11:0] thd_bin_1;
reg [11:0] thd_bin_2;
reg [11:0] thd_bin_3;
reg [11:0] thd_bin_4;
reg [11:0] thd_bin_5;

always @(*) begin
    case (freq_sel_50m_sync)
        // 1 kHz, 10 kHz and 50 kHz all become bin 40.96
        // after their respective decimation factors.
        3'b000,
        3'b001,
        3'b010: begin
            thd_bin_1 = 12'd41;
            thd_bin_2 = 12'd82;
            thd_bin_3 = 12'd123;
            thd_bin_4 = 12'd164;
            thd_bin_5 = 12'd205;
        end

        // 1 MHz at 50 MSPS.
        3'b011: begin
            thd_bin_1 = 12'd82;
            thd_bin_2 = 12'd164;
            thd_bin_3 = 12'd246;
            thd_bin_4 = 12'd328;
            thd_bin_5 = 12'd410;
        end

        // 1.5 MHz at 50 MSPS.
        3'b100: begin
            thd_bin_1 = 12'd123;
            thd_bin_2 = 12'd246;
            thd_bin_3 = 12'd369;
            thd_bin_4 = 12'd492;
            thd_bin_5 = 12'd614;
        end

        // 2 MHz at 50 MSPS.
        3'b101: begin
            thd_bin_1 = 12'd164;
            thd_bin_2 = 12'd328;
            thd_bin_3 = 12'd492;
            thd_bin_4 = 12'd655;
            thd_bin_5 = 12'd819;
        end

        // Task 5: unknown 10...100 kHz fundamental.
        3'b110: begin
            thd_bin_1 = detected_fundamental_bin;
            thd_bin_2 = detected_fundamental_bin << 1;
            thd_bin_3 =
                (detected_fundamental_bin << 1) +
                 detected_fundamental_bin;
            thd_bin_4 = detected_fundamental_bin << 2;
            thd_bin_5 =
                (detected_fundamental_bin << 2) +
                 detected_fundamental_bin;
        end

        default: begin
            thd_bin_1 = 12'd41;
            thd_bin_2 = 12'd82;
            thd_bin_3 = 12'd123;
            thd_bin_4 = 12'd164;
            thd_bin_5 = 12'd205;
        end
    endcase
end


wire thd_in_band_1;
wire thd_in_band_2;
wire thd_in_band_3;
wire thd_in_band_4;
wire thd_in_band_5;
wire thd_frequency_bins_valid;
wire [11:0] thd_band_half_width;

assign thd_frequency_bins_valid =
    !thd_auto_mode || detected_fundamental_valid;

// Fixed task-4 bins need five FFT bins total.  In automatic mode,
// multiplying a rounded fundamental bin by five can move the
// predicted harmonic center by up to 2.5 bins, so use nine bins.
assign thd_band_half_width =
    thd_auto_mode ? 12'd4 : 12'd2;

assign thd_in_band_1 =
    thd_frequency_bins_valid &&
    (fft_power_index >= thd_bin_1 - thd_band_half_width) &&
    (fft_power_index <= thd_bin_1 + thd_band_half_width);

assign thd_in_band_2 =
    thd_frequency_bins_valid &&
    (fft_power_index >= thd_bin_2 - thd_band_half_width) &&
    (fft_power_index <= thd_bin_2 + thd_band_half_width);

assign thd_in_band_3 =
    thd_frequency_bins_valid &&
    (fft_power_index >= thd_bin_3 - thd_band_half_width) &&
    (fft_power_index <= thd_bin_3 + thd_band_half_width);

assign thd_in_band_4 =
    thd_frequency_bins_valid &&
    (fft_power_index >= thd_bin_4 - thd_band_half_width) &&
    (fft_power_index <= thd_bin_4 + thd_band_half_width);

assign thd_in_band_5 =
    thd_frequency_bins_valid &&
    (fft_power_index >= thd_bin_5 - thd_band_half_width) &&
    (fft_power_index <= thd_bin_5 + thd_band_half_width);


reg [63:0] thd_power_1_accumulator = 64'd0;
reg [63:0] thd_power_2_accumulator = 64'd0;
reg [63:0] thd_power_3_accumulator = 64'd0;
reg [63:0] thd_power_4_accumulator = 64'd0;
reg [63:0] thd_power_5_accumulator = 64'd0;

reg [63:0] thd_fundamental_power = 64'd0;
reg [63:0] thd_harmonic_power    = 64'd0;
reg        thd_power_ready       = 1'b0;

always @(posedge clk_50m) begin
    if (!fft_aresetn) begin
        thd_power_1_accumulator <= 64'd0;
        thd_power_2_accumulator <= 64'd0;
        thd_power_3_accumulator <= 64'd0;
        thd_power_4_accumulator <= 64'd0;
        thd_power_5_accumulator <= 64'd0;

        thd_fundamental_power <= 64'd0;
        thd_harmonic_power    <= 64'd0;
        thd_power_ready       <= 1'b0;
    end else begin
        thd_power_ready <= 1'b0;

        if (fft_power_valid) begin
            // Natural-order FFT output starts every frame at bin 0.
            if (fft_power_index == 12'd0) begin
                thd_power_1_accumulator <= 64'd0;
                thd_power_2_accumulator <= 64'd0;
                thd_power_3_accumulator <= 64'd0;
                thd_power_4_accumulator <= 64'd0;
                thd_power_5_accumulator <= 64'd0;
            end else begin
                if (thd_in_band_1) begin
                    thd_power_1_accumulator <=
                        thd_power_1_accumulator + fft_bin_power;
                end

                if (thd_in_band_2) begin
                    thd_power_2_accumulator <=
                        thd_power_2_accumulator + fft_bin_power;
                end

                if (thd_in_band_3) begin
                    thd_power_3_accumulator <=
                        thd_power_3_accumulator + fft_bin_power;
                end

                if (thd_in_band_4) begin
                    thd_power_4_accumulator <=
                        thd_power_4_accumulator + fft_bin_power;
                end

                if (thd_in_band_5) begin
                    thd_power_5_accumulator <=
                        thd_power_5_accumulator + fft_bin_power;
                end
            end

            // Bin 4095 is outside every band, so the required sums
            // are already complete when TLAST arrives.
            //
            // The DAC sample rate is 10 MHz, so its first Nyquist
            // band ends at 5 MHz.  Harmonics above that limit are
            // mixed with DAC sampling images and clock feedthrough;
            // do not count them as independent distortion tones.
            if (fft_power_last &&
                thd_frequency_bins_valid) begin
                thd_fundamental_power <=
                    thd_power_1_accumulator;

                case (freq_sel_50m_sync)
                    // Up through the fifth harmonic is below 5 MHz.
                    3'b000,
                    3'b001,
                    3'b010: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator
                            + thd_power_4_accumulator
                            + thd_power_5_accumulator;
                    end

                    // 1 MHz: use 2, 3 and 4 MHz.  The fifth
                    // harmonic lies exactly on the DAC Nyquist edge.
                    3'b011: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator
                            + thd_power_4_accumulator;
                    end

                    // 1.5 MHz: use 3 and 4.5 MHz.
                    3'b100: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator;
                    end

                    // 2 MHz: only the second harmonic at 4 MHz is
                    // independently observable below 5 MHz.
                    3'b101: begin
                        thd_harmonic_power <=
                            thd_power_2_accumulator;
                    end

                    // Task 5 auto mode: 100 kHz * 5 = 500 kHz,
                    // safely below the 2.5 MHz Nyquist limit of
                    // the 5 MSPS effective sample rate.
                    3'b110: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator
                            + thd_power_4_accumulator
                            + thd_power_5_accumulator;
                    end

                    default: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator
                            + thd_power_4_accumulator
                            + thd_power_5_accumulator;
                    end
                endcase

                thd_power_ready <= 1'b1;
            end
        end
    end
end


// ============================================================
// Sequential fixed-point THD calculation
//
// ratio_q32 = (harmonic_power << 32) / fundamental_power
// sqrt(ratio_q32) is the amplitude ratio in Q16 format.
//
// THD display units are 0.001 percent:
//   thd_millipercent = sqrt(ratio) * 100000
//
// Example: 2196 means 2.196 percent.
// ============================================================
localparam [1:0] THD_IDLE = 2'd0;
localparam [1:0] THD_DIV  = 2'd1;
localparam [1:0] THD_SQRT = 2'd2;

reg [1:0] thd_math_state = THD_IDLE;

reg [95:0] thd_dividend  = 96'd0;
reg [63:0] thd_divisor   = 64'd0;
reg [64:0] thd_div_remainder = 65'd0;
reg [95:0] thd_div_quotient  = 96'd0;
reg [6:0]  thd_div_count     = 7'd0;

wire [64:0] thd_div_shifted_remainder;
wire        thd_div_take;
wire [64:0] thd_div_remainder_next;
wire [95:0] thd_div_quotient_next;

assign thd_div_shifted_remainder = {
    thd_div_remainder[63:0],
    thd_dividend[95]
};

assign thd_div_take =
    thd_div_shifted_remainder >= {1'b0, thd_divisor};

assign thd_div_remainder_next =
    thd_div_take
    ? thd_div_shifted_remainder - {1'b0, thd_divisor}
    : thd_div_shifted_remainder;

assign thd_div_quotient_next = {
    thd_div_quotient[94:0],
    thd_div_take
};


reg [63:0] thd_sqrt_remainder = 64'd0;
reg [63:0] thd_sqrt_result    = 64'd0;
reg [63:0] thd_sqrt_bit       = 64'd0;
reg [5:0]  thd_sqrt_count     = 6'd0;

wire [63:0] thd_sqrt_trial;
wire        thd_sqrt_take;
wire [63:0] thd_sqrt_remainder_next;
wire [63:0] thd_sqrt_result_next;

assign thd_sqrt_trial =
    thd_sqrt_result + thd_sqrt_bit;

assign thd_sqrt_take =
    thd_sqrt_remainder >= thd_sqrt_trial;

assign thd_sqrt_remainder_next =
    thd_sqrt_take
    ? thd_sqrt_remainder - thd_sqrt_trial
    : thd_sqrt_remainder;

assign thd_sqrt_result_next =
    thd_sqrt_take
    ? (thd_sqrt_result >> 1) + thd_sqrt_bit
    : (thd_sqrt_result >> 1);


wire [63:0] thd_millipercent_product;

assign thd_millipercent_product =
    thd_sqrt_result_next * 64'd100000;

reg [31:0] thd_millipercent = 32'd0;
reg        thd_result_valid = 1'b0;

always @(posedge clk_50m) begin
    if (!fft_aresetn) begin
        thd_math_state <= THD_IDLE;

        thd_dividend      <= 96'd0;
        thd_divisor       <= 64'd0;
        thd_div_remainder <= 65'd0;
        thd_div_quotient  <= 96'd0;
        thd_div_count     <= 7'd0;

        thd_sqrt_remainder <= 64'd0;
        thd_sqrt_result    <= 64'd0;
        thd_sqrt_bit       <= 64'd0;
        thd_sqrt_count     <= 6'd0;

        thd_millipercent <= 32'd0;
        thd_result_valid <= 1'b0;
    end else begin
        thd_result_valid <= 1'b0;

        case (thd_math_state)
            THD_IDLE: begin
                if (thd_power_ready) begin
                    if (thd_fundamental_power == 64'd0) begin
                        thd_millipercent <= 32'd0;
                        thd_result_valid <= 1'b1;
                    end else begin
                        thd_dividend <= {
                            thd_harmonic_power,
                            32'd0
                        };

                        thd_divisor       <=
                            thd_fundamental_power;
                        thd_div_remainder <= 65'd0;
                        thd_div_quotient  <= 96'd0;
                        thd_div_count     <= 7'd0;
                        thd_math_state    <= THD_DIV;
                    end
                end
            end

            THD_DIV: begin
                thd_dividend <= {
                    thd_dividend[94:0],
                    1'b0
                };

                thd_div_remainder <=
                    thd_div_remainder_next;

                thd_div_quotient <=
                    thd_div_quotient_next;

                if (thd_div_count == 7'd95) begin
                    thd_sqrt_remainder <=
                        thd_div_quotient_next[63:0];

                    thd_sqrt_result <= 64'd0;
                    thd_sqrt_bit <=
                        64'h4000_0000_0000_0000;
                    thd_sqrt_count <= 6'd0;
                    thd_math_state <= THD_SQRT;
                end else begin
                    thd_div_count <= thd_div_count + 7'd1;
                end
            end

            THD_SQRT: begin
                thd_sqrt_remainder <=
                    thd_sqrt_remainder_next;

                thd_sqrt_result <=
                    thd_sqrt_result_next;

                thd_sqrt_bit <= thd_sqrt_bit >> 2;

                if (thd_sqrt_count == 6'd31) begin
                    thd_millipercent <=
                        (thd_millipercent_product + 64'd32768)
                        >> 16;

                    thd_result_valid <= 1'b1;
                    thd_math_state <= THD_IDLE;
                end else begin
                    thd_sqrt_count <= thd_sqrt_count + 6'd1;
                end
            end

            default: begin
                thd_math_state <= THD_IDLE;
            end
        endcase
    end
end


// ============================================================
// Stable THD display value
//
// Raw FFT-based THD estimates vary slightly from frame to frame.
// Average a power-of-two number of frames before updating the
// seven-segment display.  The frame count is selected so that all
// fixed and automatic ranges refresh in roughly 1.7 to 2.7 seconds.
// ============================================================
reg [14:0] thd_average_terminal_count;
reg [3:0]  thd_average_shift;

always @(*) begin
    case (freq_sel_50m_sync)
        3'b000: begin
            // 64 frames, approximately 2.621 s.
            thd_average_terminal_count = 15'd63;
            thd_average_shift = 4'd6;
        end

        3'b001: begin
            // 512 frames, approximately 2.097 s.
            thd_average_terminal_count = 15'd511;
            thd_average_shift = 4'd9;
        end

        3'b010,
        3'b110: begin
            // 2048 frames, approximately 1.678 s.
            thd_average_terminal_count = 15'd2047;
            thd_average_shift = 4'd11;
        end

        3'b011,
        3'b100,
        3'b101: begin
            // 32768 frames, approximately 2.684 s.
            thd_average_terminal_count = 15'd32767;
            thd_average_shift = 4'd15;
        end

        default: begin
            thd_average_terminal_count = 15'd63;
            thd_average_shift = 4'd6;
        end
    endcase
end


reg [47:0] thd_average_sum   = 48'd0;
reg [14:0] thd_average_count = 15'd0;

wire [47:0] thd_average_sum_next;
wire [47:0] thd_average_rounding;

assign thd_average_sum_next =
    thd_average_sum + {16'd0, thd_millipercent};

assign thd_average_rounding =
    48'd1 << (thd_average_shift - 1'b1);

reg [31:0] thd_display_millipercent = 32'd0;
reg        thd_update_toggle = 1'b0;

always @(posedge clk_50m) begin
    if (!fft_aresetn) begin
        thd_average_sum   <= 48'd0;
        thd_average_count <= 15'd0;
        thd_display_millipercent <= 32'd0;
        thd_update_toggle <= 1'b0;
    end else if (thd_result_valid) begin
        if (thd_average_count ==
            thd_average_terminal_count) begin

            thd_display_millipercent <=
                (thd_average_sum_next + thd_average_rounding)
                >> thd_average_shift;

            thd_average_sum   <= 48'd0;
            thd_average_count <= 15'd0;
            thd_update_toggle <= ~thd_update_toggle;
        end else begin
            thd_average_sum <= thd_average_sum_next;
            thd_average_count <= thd_average_count + 15'd1;
        end
    end
end


wire fft_error_any;

assign fft_error_any =
       fft_event_tlast_unexpected
     | fft_event_tlast_missing
     | fft_event_status_channel_halt
     | fft_event_data_in_channel_halt
     | fft_event_data_out_channel_halt;
    // ============================================================
    // ILA debug probes
    //
    // PROBE0: 11 bits - centered ADC sample
    // PROBE1: 12 bits - active/detected fundamental bin
    // PROBE2: 32 bits - THD in 0.001-percent units
    // PROBE3: 32 bits - low half of fundamental band power
    // PROBE4:  1 bit  - new THD result pulse
    // PROBE5:  1 bit  - registered FFT frame last
    // PROBE6:  1 bit  - FFT error summary
    // ============================================================
    ila_adc u_ila_adc (
        .clk    (clk_50m),
        .probe0 (adc_centered),
        .probe1 (thd_bin_1),
        .probe2 (thd_millipercent),
        .probe3 (thd_fundamental_power[31:0]),
        .probe4 (thd_result_valid),
        .probe5 (fft_power_last),
        .probe6 (fft_error_any)
    );


    // ============================================================
    // Transfer the frequency and THD results into the 100 MHz
    // display domain.  The update toggles indicate when each stable
    // multi-bit result has changed.
    // ============================================================
    reg        display_mode_meta = 1'b0;
    reg        display_mode_sync = 1'b0;
    reg        display_mode_last = 1'b0;

    reg thd_display_select_meta = 1'b0;
    reg thd_display_select_sync = 1'b0;
    reg thd_display_select_last = 1'b0;

    reg [31:0] frequency_display_value_meta = 32'd0;
    reg [31:0] frequency_display_value_sync = 32'd0;

    reg frequency_display_update_meta = 1'b0;
    reg frequency_display_update_sync = 1'b0;
    reg frequency_display_update_last = 1'b0;

    reg [31:0] thd_display_value_meta = 32'd0;
    reg [31:0] thd_display_value_sync = 32'd0;

    reg thd_display_update_meta = 1'b0;
    reg thd_display_update_sync = 1'b0;
    reg thd_display_update_last = 1'b0;


    // ============================================================
    // Binary-to-BCD conversion
    //
    // A double-dabble conversion takes 32 clk_in cycles.  At
    // 100 MHz this is only 320 ns, whereas measurements update once
    // every two seconds.
    //
    // display_bcd[31:28] is the leftmost decimal digit.
    // display_bcd[3:0]   is the rightmost decimal digit.
    // ============================================================
    reg [63:0] bcd_shift     = 64'd0;
    reg [5:0]  bcd_iteration = 6'd0;
    reg        bcd_busy      = 1'b0;
    reg [31:0] display_bcd   = 32'd0;

    reg [63:0] bcd_adjusted;
    integer bcd_digit_index;

    always @(*) begin
        bcd_adjusted = bcd_shift;

        for (bcd_digit_index = 0;
             bcd_digit_index < 8;
             bcd_digit_index = bcd_digit_index + 1) begin

            if (bcd_shift[
                    32 + bcd_digit_index * 4 +: 4
                ] >= 4'd5) begin

                bcd_adjusted[
                    32 + bcd_digit_index * 4 +: 4
                ] = bcd_shift[
                    32 + bcd_digit_index * 4 +: 4
                ] + 4'd3;
            end
        end
    end

    wire [63:0] bcd_shift_next;
    assign bcd_shift_next = bcd_adjusted << 1;


    always @(posedge clk_in) begin
        // Synchronize the two physical display-selection switches.
        display_mode_meta <= display_mode;
        display_mode_sync <= display_mode_meta;
        display_mode_last <= display_mode_sync;

        thd_display_select_meta <= thd_display_select;
        thd_display_select_sync <= thd_display_select_meta;
        thd_display_select_last <= thd_display_select_sync;

        // Synchronize the stable measured-frequency result.
        frequency_display_value_meta <= measured_frequency;
        frequency_display_value_sync <=
            frequency_display_value_meta;

        frequency_display_update_meta <=
            measurement_update_toggle;
        frequency_display_update_sync <=
            frequency_display_update_meta;
        frequency_display_update_last <=
            frequency_display_update_sync;

        // Synchronize the stable THD-result bus.
        thd_display_value_meta <= thd_display_millipercent;
        thd_display_value_sync <= thd_display_value_meta;

        // Synchronize and detect a new-result notification.
        thd_display_update_meta <= thd_update_toggle;
        thd_display_update_sync <= thd_display_update_meta;
        thd_display_update_last <= thd_display_update_sync;

        // Reconvert immediately when either display switch changes.
        if ((display_mode_sync != display_mode_last) ||
            (thd_display_select_sync !=
             thd_display_select_last)) begin

            bcd_shift <= {
                32'd0,
                thd_display_select_sync
                ? thd_display_value_sync
                : frequency_display_value_sync
            };

            bcd_iteration <= 6'd0;
            bcd_busy      <= 1'b1;

        end else if (display_mode_sync &&
                     !thd_display_select_sync &&
                     (frequency_display_update_sync !=
                      frequency_display_update_last)) begin

            bcd_shift <= {
                32'd0,
                frequency_display_value_sync
            };

            bcd_iteration <= 6'd0;
            bcd_busy      <= 1'b1;

        end else if (display_mode_sync &&
                     thd_display_select_sync &&
                     (thd_display_update_sync !=
                      thd_display_update_last)) begin

            bcd_shift <= {
                32'd0,
                thd_display_value_sync
            };

            bcd_iteration <= 6'd0;
            bcd_busy      <= 1'b1;

        end else if (bcd_busy) begin
            bcd_shift <= bcd_shift_next;

            if (bcd_iteration == 6'd31) begin
                display_bcd <= bcd_shift_next[63:32];
                bcd_busy    <= 1'b0;
            end else begin
                bcd_iteration <= bcd_iteration + 6'd1;
            end
        end
    end


    // ============================================================
    // Seven-segment display scanning
    //
    // Silk-screen switch 4 (display_mode) = 0:
    //     student ID 20051121
    //
    // Silk-screen switch 4 = 1, switch 3 = 0:
    //     measured frequency in Hz
    //
    // Silk-screen switch 4 = 1, switch 3 = 1:
    //     THD percentage with three decimals
    //
    // THD values use 0.001-percent units with leading zeros:
    //       2.196 percent -> 00002.196
    // ============================================================
    reg [31:0] scan_count = 32'd0;
    reg [2:0]  scan_index = 3'd0;

    reg [3:0] digit;
    reg [7:0] segment_code;

    always @(posedge clk_in) begin
        if (scan_count == SCAN_CYCLES - 1) begin
            scan_count <= 32'd0;
            scan_index <= scan_index + 3'd1;
        end else begin
            scan_count <= scan_count + 32'd1;
        end
    end


    // Select the digit for the current display position.
    always @(*) begin
        if (!display_mode_sync) begin
            // Student ID: 20051121
            case (scan_index)
                3'd0: digit = 4'd2;
                3'd1: digit = 4'd0;
                3'd2: digit = 4'd0;
                3'd3: digit = 4'd5;
                3'd4: digit = 4'd1;
                3'd5: digit = 4'd1;
                3'd6: digit = 4'd2;
                3'd7: digit = 4'd1;
                default: digit = 4'd0;
            endcase
        end else begin
            // Selected measured frequency or THD result.
            case (scan_index)
                3'd0: digit = display_bcd[31:28];
                3'd1: digit = display_bcd[27:24];
                3'd2: digit = display_bcd[23:20];
                3'd3: digit = display_bcd[19:16];
                3'd4: digit = display_bcd[15:12];
                3'd5: digit = display_bcd[11:8];
                3'd6: digit = display_bcd[7:4];
                3'd7: digit = display_bcd[3:0];
                default: digit = 4'd0;
            endcase
        end
    end


    // Active-high segments: {dp, g, f, e, d, c, b, a}
    always @(*) begin
        case (digit)
            4'd0: segment_code = 8'h3F;
            4'd1: segment_code = 8'h06;
            4'd2: segment_code = 8'h5B;
            4'd3: segment_code = 8'h4F;
            4'd4: segment_code = 8'h66;
            4'd5: segment_code = 8'h6D;
            4'd6: segment_code = 8'h7D;
            4'd7: segment_code = 8'h07;
            4'd8: segment_code = 8'h7F;
            4'd9: segment_code = 8'h6F;
            default: segment_code = 8'h00;
        endcase
    end


    initial begin
        seg_cs_pin     = 8'h00;
        seg_data_0_pin = 8'h00;
        seg_data_1_pin = 8'h00;
    end


    // Blank the display briefly while switching digits.
    always @(posedge clk_in) begin
        if (scan_count == 0) begin
            seg_cs_pin <= 8'h00;

            if (scan_index < 4) begin
                seg_data_0_pin <=
                    (display_mode_sync &&
                     thd_display_select_sync &&
                     (scan_index == 3'd4))
                    ? (segment_code | 8'h80)
                    : segment_code;
                seg_data_1_pin <= 8'h00;
            end else begin
                seg_data_0_pin <= 8'h00;
                seg_data_1_pin <=
                    (display_mode_sync &&
                     thd_display_select_sync &&
                     (scan_index == 3'd4))
                    ? (segment_code | 8'h80)
                    : segment_code;
            end
        end else begin
            seg_cs_pin <=
                8'b0000_0001 << scan_index;
        end
    end

endmodule
