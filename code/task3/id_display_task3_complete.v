`timescale 1ns / 1ps

module id_display #(
    parameter integer SCAN_CYCLES = 100_000
)(
    input  wire        clk_in,
    input  wire [2:0]  freq_sel,
    input  wire        display_mode,

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
        end else if (!dds_config_sent ||
                     (freq_sel_sync != freq_sel_last)) begin

            freq_sel_last    <= freq_sel_sync;
            dds_config_data  <=
                select_frequency_word(freq_sel_sync);
            dds_config_valid <= 1'b1;
            dds_config_sent  <= 1'b1;
        end
    end


    // ============================================================
    // DDS Compiler
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
        end else if (dds_valid) begin
            dac_data_reg <= {
                ~dds_data[15],
                 dds_data[14:2]
            };
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
    // ILA debug probes
    //
    // PROBE0: 10 bits - raw ADC sample
    // PROBE1: 10 bits - calculated ADC midpoint
    // PROBE2:  1 bit  - one-cycle rising pulse
    // PROBE3: 32 bits - measured frequency in Hz
    // PROBE4:  1 bit  - calibration complete
    // ============================================================
    ila_adc u_ila_adc (
        .clk    (clk_50m),
        .probe0 (adc_sample),
        .probe1 (adc_midpoint),
        .probe2 (adc_rising_pulse),
        .probe3 (measured_frequency),
        .probe4 (calibration_done)
    );


    // ============================================================
    // Transfer the measured frequency into the 100 MHz display
    // domain.
    //
    // measured_frequency remains unchanged between measurements.
    // The update toggle tells this domain when a complete new value
    // is available, so the eight display digits all use one result.
    // ============================================================
    reg        display_mode_meta = 1'b0;
    reg        display_mode_sync = 1'b0;

    reg [31:0] measured_frequency_meta = 32'd0;
    reg [31:0] measured_frequency_sync = 32'd0;

    reg measurement_update_meta = 1'b0;
    reg measurement_update_sync = 1'b0;
    reg measurement_update_last = 1'b0;


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
        // Synchronize the physical display-mode switch.
        display_mode_meta <= display_mode;
        display_mode_sync <= display_mode_meta;

        // Synchronize the stable frequency-result bus.
        measured_frequency_meta <= measured_frequency;
        measured_frequency_sync <= measured_frequency_meta;

        // Synchronize and detect a new-result notification.
        measurement_update_meta <= measurement_update_toggle;
        measurement_update_sync <= measurement_update_meta;
        measurement_update_last <= measurement_update_sync;

        if (measurement_update_sync !=
            measurement_update_last) begin

            bcd_shift <= {
                32'd0,
                measured_frequency_sync
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
    // display_mode = 0: student ID 20051121
    // display_mode = 1: measured frequency in Hz
    //
    // Frequency values use all eight digits with leading zeros:
    //       1 kHz -> 00001000
    //      50 kHz -> 00050000
    //       1 MHz -> 01000000
    //       2 MHz -> 02000000
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
            // Measured frequency in Hz.
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
                seg_data_0_pin <= segment_code;
                seg_data_1_pin <= 8'h00;
            end else begin
                seg_data_0_pin <= 8'h00;
                seg_data_1_pin <= segment_code;
            end
        end else begin
            seg_cs_pin <=
                8'b0000_0001 << scan_index;
        end
    end

endmodule
