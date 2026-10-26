`timescale 1ns / 1ps

// Task 3 focused digital self-check.
//
// This testbench keeps the verified top-level RTL unchanged.  To avoid a
// two-second simulation for every case, it advances the already verified
// gate counter to its final cycle.  It checks three task-specific behaviors:
//   1. hysteretic rising-crossing detection produces one pulse per cycle;
//   2. 100,000 crossings in a two-second gate become 50,000 Hz;
//   3. the completed binary result becomes eight BCD display digits.
//
// The analog DAC/ADC path is not modeled here.  That path is supported by
// the archived ILA captures and board photographs.
module tb_task3_frequency_measurement;

    reg         clk_in       = 1'b0;
    reg  [2:0]  freq_sel     = 3'b010;
    reg         display_mode = 1'b1;
    reg  [9:0]  ad_in        = 10'd300;

    wire        dac_clk;
    wire [13:0] dac_data;
    wire        clk_ad;
    wire        adc_clamp;
    wire [7:0]  seg_cs_pin;
    wire [7:0]  seg_data_0_pin;
    wire [7:0]  seg_data_1_pin;

    integer pass_count = 0;
    integer fail_count = 0;

    always #5 clk_in = ~clk_in;

    id_display #(
        .SCAN_CYCLES(10)
    ) dut (
        .clk_in         (clk_in),
        .freq_sel       (freq_sel),
        .display_mode   (display_mode),
        .dac_clk        (dac_clk),
        .dac_data       (dac_data),
        .ad_in          (ad_in),
        .clk_ad         (clk_ad),
        .adc_clamp      (adc_clamp),
        .seg_cs_pin     (seg_cs_pin),
        .seg_data_0_pin (seg_data_0_pin),
        .seg_data_1_pin (seg_data_1_pin)
    );

    task check_bit;
        input actual;
        input expected;
        input [8*80-1:0] label_text;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s", label_text);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s actual=%b expected=%b",
                         label_text, actual, expected);
            end
        end
    endtask

    task check_word;
        input [31:0] actual;
        input [31:0] expected;
        input [8*80-1:0] label_text;
        begin
            if (actual === expected) begin
                pass_count = pass_count + 1;
                $display("PASS: %0s = %0d", label_text, actual);
            end else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s actual=%0d expected=%0d",
                         label_text, actual, expected);
            end
        end
    endtask

    initial begin
        wait (dut.clk_10m_locked === 1'b1);
        repeat (4) @(posedge dut.clk_50m);

        // Enter the measurement state directly.  Thresholds represent an
        // already completed calibration with low=400 and high=600.
        force dut.adc_settle_count  = 16'd49_999;
        force dut.calibration_done = 1'b1;
        force dut.adc_threshold_low  = 10'd400;
        force dut.adc_threshold_high = 10'd600;

        // Below low threshold: detector is armed and no pulse is emitted.
        ad_in = 10'd300;
        repeat (3) @(posedge dut.clk_50m);
        #1 check_bit(dut.adc_rising_pulse, 1'b0,
                     "below low threshold produces no pulse");

        // Cross the high threshold.  adc_sample is a registered input, so
        // allow one capture edge and one detector edge.
        ad_in = 10'd700;
        @(posedge dut.clk_50m);
        @(posedge dut.clk_50m);
        #1 check_bit(dut.adc_rising_pulse, 1'b1,
                     "first high-threshold crossing produces one pulse");

        // Remaining high must not produce a second pulse.
        @(posedge dut.clk_50m);
        #1 check_bit(dut.adc_rising_pulse, 1'b0,
                     "remaining above high threshold does not retrigger");

        // Return below the low threshold to re-arm, then cross high again.
        ad_in = 10'd300;
        repeat (3) @(posedge dut.clk_50m);
        ad_in = 10'd700;
        @(posedge dut.clk_50m);
        @(posedge dut.clk_50m);
        #1 check_bit(dut.adc_rising_pulse, 1'b1,
                     "falling below low threshold rearms detector");

        // Check the final gate-cycle arithmetic without simulating the full
        // 100,000,000 ADC clocks.  Keep the current sample below threshold,
        // so the stored 99,999 count plus rounding yields 50,000 Hz.
        ad_in = 10'd300;
        repeat (3) @(posedge dut.clk_50m);
        force dut.frequency_gate_count = 27'd99_999_999;
        force dut.waveform_cycle_count = 32'd99_999;
        @(posedge dut.clk_50m);
        #1 check_word(dut.measured_frequency, 32'd50_000,
                      "two-second gate result");
        release dut.frequency_gate_count;
        release dut.waveform_cycle_count;

        // The update toggle crosses to clk_in, then Double Dabble takes
        // 32 cycles.  The final eight BCD digits must read 00050000.
        repeat (80) @(posedge clk_in);
        #1 check_word(dut.display_bcd, 32'h0005_0000,
                      "binary 50000 converts to BCD 00050000");

        release dut.adc_settle_count;
        release dut.calibration_done;
        release dut.adc_threshold_low;
        release dut.adc_threshold_high;

        $display("Task 3 Testbench complete: PASS=%0d, FAIL=%0d",
                 pass_count, fail_count);
        if (fail_count == 0)
            $display("TASK 3 RESULT: PASS");
        else
            $display("TASK 3 RESULT: FAIL");

        #20 $finish;
    end

endmodule


// Behavioral stubs used only by this focused testbench.
module clk_wiz_10m (
    output reg clk_out1,
    output reg clk_out2,
    input  wire reset,
    output reg locked,
    input  wire clk_in1
);
    initial begin
        clk_out1 = 1'b0;
        forever #50 clk_out1 = ~clk_out1;
    end

    initial begin
        clk_out2 = 1'b0;
        forever #10 clk_out2 = ~clk_out2;
    end

    initial begin
        locked = 1'b0;
        #120 locked = 1'b1;
    end
endmodule


module dds_sine (
    input  wire               aclk,
    input  wire               s_axis_config_tvalid,
    input  wire [31:0]        s_axis_config_tdata,
    output reg                m_axis_data_tvalid,
    output reg signed [15:0]  m_axis_data_tdata
);
    initial begin
        m_axis_data_tvalid = 1'b0;
        m_axis_data_tdata  = 16'sd0;
    end

    always @(posedge aclk) begin
        m_axis_data_tvalid <= 1'b1;
        m_axis_data_tdata  <= 16'sd0;
    end
endmodule


module ila_adc (
    input wire        clk,
    input wire [9:0]  probe0,
    input wire [9:0]  probe1,
    input wire        probe2,
    input wire [31:0] probe3,
    input wire        probe4
);
endmodule


module ODDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
)(
    output reg Q,
    input wire C,
    input wire CE,
    input wire D1,
    input wire D2,
    input wire R,
    input wire S
);
    initial Q = INIT;

    always @(posedge C) begin
        if (R)
            Q <= 1'b0;
        else if (S)
            Q <= 1'b1;
        else if (CE)
            Q <= D1;
    end

    always @(negedge C) begin
        if (CE)
            Q <= D2;
    end
endmodule
