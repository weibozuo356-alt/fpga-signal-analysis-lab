`timescale 1ns / 1ps

// ============================================================
// Task 2 frequency-resolution display Testbench
//
// This focused Testbench checks only the new freq_sel=111 display
// path.  Lightweight IP stubs keep the test independent of the
// Clock Wizard, DDS, FFT and ILA generated simulation products.
// ============================================================
module tb_task2_resolution_display;

    reg        clk_in = 1'b0;
    reg [2:0]  freq_sel = 3'b000;
    reg        display_mode = 1'b0;
    reg        thd_display_select = 1'b0;
    reg [9:0]  ad_in = 10'd0;

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
        .SCAN_CYCLES(2)
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

    task automatic check;
        input condition;
        input [8*80-1:0] message;
        begin
            if (condition) begin
                $display("PASS: %0s", message);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: %0s", message);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk_in);

        // Frequency page + freq_sel=111 must show 0.0023283 Hz.
        display_mode = 1'b1;
        thd_display_select = 1'b0;
        freq_sel = 3'b111;

        wait (dut.display_mode_sync === 1'b1);
        wait (dut.freq_sel_display_sync === 3'b111);
        wait (dut.bcd_busy === 1'b1);
        wait (dut.bcd_busy === 1'b0);
        #1;

        check(dut.display_bcd === 32'h0002_3283,
              "freq_sel=111 BCD payload is 00023283");
        check(dut.dds_resolution_display_active === 1'b1,
              "resolution page is active only on frequency display");

        force dut.scan_index = 3'd0;
        #1;
        check(dut.measurement_decimal_point_active === 1'b1,
              "resolution decimal point follows the leftmost zero");
        force dut.scan_count = 32'd0;
        @(posedge clk_in);
        #1;
        check(seg_data_0_pin[7] === 1'b1,
              "physical segment-data output drives the decimal point");
        release dut.scan_count;
        release dut.scan_index;

        // THD page must retain the original digit-4 decimal point.
        thd_display_select = 1'b1;
        wait (dut.thd_display_select_sync === 1'b1);
        force dut.scan_index = 3'd4;
        #1;
        check(dut.measurement_decimal_point_active === 1'b1,
              "THD decimal point remains at digit 4");
        check(dut.dds_resolution_display_active === 1'b0,
              "freq_sel=111 does not replace the THD page");
        release dut.scan_index;

        // Student-ID page must remain unchanged.
        display_mode = 1'b0;
        wait (dut.display_mode_sync === 1'b0);
        force dut.scan_index = 3'd0;
        #1;
        check(dut.digit === 4'd2,
              "student-ID page still starts with digit 2");
        check(dut.measurement_decimal_point_active === 1'b0,
              "student-ID page has no measurement decimal point");
        release dut.scan_index;

        $display("Task 2 resolution-display test: PASS=%0d FAIL=%0d",
                 pass_count, fail_count);

        if (fail_count == 0)
            $display("TASK 2 RESOLUTION DISPLAY RESULT: PASS");
        else
            $display("TASK 2 RESOLUTION DISPLAY RESULT: FAIL");

        #20;
        $finish;
    end

endmodule


// ------------------------------------------------------------
// Minimal generated-IP and primitive stubs used by this focused test.
// ------------------------------------------------------------
module clk_wiz_10m (
    output wire clk_out1,
    output wire clk_out2,
    input  wire reset,
    output wire locked,
    input  wire clk_in1
);
    assign clk_out1 = clk_in1;
    assign clk_out2 = clk_in1;
    assign locked = ~reset;
endmodule

module dds_sine (
    input  wire        aclk,
    input  wire        s_axis_config_tvalid,
    input  wire [31:0] s_axis_config_tdata,
    output wire        m_axis_data_tvalid,
    output wire [15:0] m_axis_data_tdata
);
    assign m_axis_data_tvalid = 1'b1;
    assign m_axis_data_tdata = 16'd0;
endmodule

module ODDR #(
    parameter DDR_CLK_EDGE = "OPPOSITE_EDGE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output wire Q,
    input  wire C,
    input  wire CE,
    input  wire D1,
    input  wire D2,
    input  wire R,
    input  wire S
);
    assign Q = CE ? C : INIT;
endmodule

module fft_thd (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [7:0]  s_axis_config_tdata,
    input  wire        s_axis_config_tvalid,
    output wire        s_axis_config_tready,
    input  wire [31:0] s_axis_data_tdata,
    input  wire        s_axis_data_tvalid,
    output wire        s_axis_data_tready,
    input  wire        s_axis_data_tlast,
    output wire [63:0] m_axis_data_tdata,
    output wire [15:0] m_axis_data_tuser,
    output wire        m_axis_data_tvalid,
    input  wire        m_axis_data_tready,
    output wire        m_axis_data_tlast,
    output wire        event_frame_started,
    output wire        event_tlast_unexpected,
    output wire        event_tlast_missing,
    output wire        event_status_channel_halt,
    output wire        event_data_in_channel_halt,
    output wire        event_data_out_channel_halt
);
    assign s_axis_config_tready = 1'b1;
    assign s_axis_data_tready = 1'b1;
    assign m_axis_data_tdata = 64'd0;
    assign m_axis_data_tuser = 16'd0;
    assign m_axis_data_tvalid = 1'b0;
    assign m_axis_data_tlast = 1'b0;
    assign event_frame_started = 1'b0;
    assign event_tlast_unexpected = 1'b0;
    assign event_tlast_missing = 1'b0;
    assign event_status_channel_halt = 1'b0;
    assign event_data_in_channel_halt = 1'b0;
    assign event_data_out_channel_halt = 1'b0;
endmodule

module ila_adc (
    input wire               clk,
    input wire signed [10:0] probe0,
    input wire        [11:0] probe1,
    input wire        [31:0] probe2,
    input wire        [31:0] probe3,
    input wire               probe4,
    input wire               probe5,
    input wire               probe6
);
endmodule
