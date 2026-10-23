`timescale 1ns / 1ps

// ============================================================
// Task 2 dedicated Testbench
//
// Purpose:
//   1. Drive all six freq_sel switch combinations used by Task 2.
//   2. Check the 32-bit DDS frequency-control word sent by the
//      final id_display top-level design.
//   3. Measure the frequency represented by the 14-bit DAC data.
//
// The measured signal is the digital sample stream sent to the
// external DAC.  The analog voltage amplitude and filter response
// belong to the physical DAC board and cannot be reproduced by
// this purely digital simulation.
// ============================================================
module tb_task2_dds;

    // --------------------------------------------------------
    // Inputs driven by the Testbench
    // --------------------------------------------------------
    reg        clk_in = 1'b0;
    reg [2:0]  freq_sel = 3'b000;
    reg        display_mode = 1'b0;
    reg        thd_display_select = 1'b0;
    reg [9:0]  ad_in = 10'd0;

    // --------------------------------------------------------
    // Outputs observed from the final top-level design
    // --------------------------------------------------------
    wire        dac_clk;
    wire [13:0] dac_data;
    wire        clk_ad;
    wire        adc_clamp;
    wire [7:0]  seg_cs_pin;
    wire [7:0]  seg_data_0_pin;
    wire [7:0]  seg_data_1_pin;

    integer pass_count = 0;
    integer fail_count = 0;

    // 100 MHz board clock: toggle every 5 ns.
    always #5 clk_in = ~clk_in;

    // Final integrated design under test.
    // The smaller scan count only accelerates seven-segment
    // scanning during simulation; it does not alter DDS timing.
    id_display #(
        .SCAN_CYCLES(10)
    ) dut (
        .clk_in             (clk_in),
        .freq_sel           (freq_sel),
        .display_mode       (display_mode),
        .thd_display_select (thd_display_select),
        .dac_clk            (dac_clk),
        .dac_data           (dac_data),
        .ad_in              (ad_in),
        .clk_ad             (clk_ad),
        .adc_clamp          (adc_clamp),
        .seg_cs_pin         (seg_cs_pin),
        .seg_data_0_pin     (seg_data_0_pin),
        .seg_data_1_pin     (seg_data_1_pin)
    );


    // --------------------------------------------------------
    // Wait for one negative-to-positive zero crossing.
    //
    // dac_data uses unsigned offset-binary format, so 14'd8192
    // represents zero analog amplitude.  Sampling at the rising
    // edge of dac_clk matches the external DAC sampling instant.
    // --------------------------------------------------------
    task automatic wait_for_rising_zero_crossing;
        reg [13:0] previous_sample;
        begin : find_crossing
            @(posedge dac_clk);
            #1;
            previous_sample = dac_data;

            forever begin
                @(posedge dac_clk);
                #1;

                if ((previous_sample < 14'd8192) &&
                    (dac_data >= 14'd8192)) begin
                    disable find_crossing;
                end

                previous_sample = dac_data;
            end
        end
    endtask


    // --------------------------------------------------------
    // Select one frequency, check K, and measure the average
    // period across several output cycles.
    // --------------------------------------------------------
    task automatic check_frequency;
        input [2:0]  select_code;
        input [31:0] expected_control_word;
        input integer expected_frequency_hz;
        input integer number_of_periods;

        integer crossing_index;
        time    first_crossing_time;
        time    last_crossing_time;
        real    elapsed_time_ns;
        real    measured_frequency_hz;
        real    error_percent;

        begin
            freq_sel = select_code;

            // The switch passes through a two-register
            // synchronizer before the one-cycle configuration
            // pulse is generated in the 10 MHz DDS clock domain.
            @(posedge dut.clk_10m);
            wait (dut.dds_config_valid === 1'b1);
            #1;

            if (dut.dds_config_data === expected_control_word) begin
                $display("PASS K: freq_sel=%b, K=%0d",
                         select_code, dut.dds_config_data);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL K: freq_sel=%b, expected K=%0d, actual K=%0d",
                         select_code,
                         expected_control_word,
                         dut.dds_config_data);
                fail_count = fail_count + 1;
            end

            // Allow the configured DDS pipeline to produce new
            // samples before searching for a zero crossing.
            repeat (20) @(posedge dac_clk);

            wait_for_rising_zero_crossing;
            first_crossing_time = $time;

            for (crossing_index = 0;
                 crossing_index < number_of_periods;
                 crossing_index = crossing_index + 1) begin
                wait_for_rising_zero_crossing;
            end

            last_crossing_time = $time;
            elapsed_time_ns = last_crossing_time -
                              first_crossing_time;

            measured_frequency_hz =
                number_of_periods * 1.0e9 / elapsed_time_ns;

            error_percent =
                (measured_frequency_hz - expected_frequency_hz)
                * 100.0 / expected_frequency_hz;

            if (error_percent < 0.0) begin
                error_percent = -error_percent;
            end

            // One-percent tolerance includes the 100 ns sampling
            // quantization of the 10 MHz DAC sample stream.
            if (error_percent <= 1.0) begin
                $display("PASS F: freq_sel=%b, expected=%0d Hz, measured=%0.3f Hz, error=%0.5f%%",
                         select_code,
                         expected_frequency_hz,
                         measured_frequency_hz,
                         error_percent);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL F: freq_sel=%b, expected=%0d Hz, measured=%0.3f Hz, error=%0.5f%%",
                         select_code,
                         expected_frequency_hz,
                         measured_frequency_hz,
                         error_percent);
                fail_count = fail_count + 1;
            end
        end
    endtask


    initial begin
        $timeformat(-9, 3, " ns", 12);

        // Wait until the Clock Wizard has produced stable 10 MHz
        // and 50 MHz clocks.
        wait (dut.clk_10m_locked === 1'b1);

        // freq_sel, expected K, expected frequency, measured cycles
        check_frequency(3'b000, 32'd429497,    1_000,     3);
        check_frequency(3'b001, 32'd4294967,   10_000,    5);
        check_frequency(3'b010, 32'd21474836,  50_000,   10);
        check_frequency(3'b011, 32'd429496730, 1_000_000, 20);
        check_frequency(3'b100, 32'd644245094, 1_500_000, 30);
        check_frequency(3'b101, 32'd858993459, 2_000_000, 20);

        $display("==================================================");
        $display("Task 2 Testbench complete: PASS=%0d, FAIL=%0d",
                 pass_count, fail_count);
        $display("==================================================");

        if (fail_count == 0) begin
            $display("TASK 2 RESULT: PASS");
        end else begin
            $display("TASK 2 RESULT: FAIL");
        end

        #100;
        $finish;
    end

endmodule
