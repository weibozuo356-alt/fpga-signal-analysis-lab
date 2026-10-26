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

    // 任务三：外接10位ADC接口
    // ad_in是ADC对模拟电压量化后直接输出的0～1023数字码；
    // clk_ad为50 MHz采样时钟，adc_clamp固定为0以关闭钳位。
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
    // 任务三：ADC钳位控制，低电平表示关闭钳位功能。
    // ============================================================
    assign adc_clamp = 1'b0;


    // ============================================================
    // 任务三：用ODDR向外部ADC转发50 MHz采样时钟。
    // 采样周期为20 ns；这是ADC采样间隔，不是被测正弦波周期。
    // ============================================================
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_adc_clk_oddr (
        .Q  (clk_ad),          // 输出到外部ADC的采样时钟
        .C  (clk_50m),         // 内部50 MHz时钟
        .CE (clk_10m_locked),  // 时钟稳定后才允许输出
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
    // 在50 MHz上升沿锁存外部ADC的10位结果。
    // 例如adc_sample=650表示ADC当前量化码为650，并非FPGA计算出650。
    // ============================================================
    reg [9:0] adc_sample = 10'd0; // 当前ADC样本，范围0～1023

    always @(posedge clk_50m) begin
        if (!clk_10m_locked) begin
            adc_sample <= 10'd0;
        end else begin
            adc_sample <= ad_in; // 每20 ns采入一个新码
        end
    end


    // ============================================================
    // 任务三核心：ADC自动校准与频率测量
    //
    // 上电或切换频率后依次执行：
    // 1. 等待1 ms，使DDS、DAC及模拟回环的新波形稳定；
    // 2. 在10 ms内记录ADC最小值和最大值；
    // 3. 计算中点M、范围R以及高低迟滞门限；
    // 4. 每个正弦周期只产生一次有效上升穿越脉冲；
    // 5. 在2 s内累计穿越次数N，N/2即为频率Hz。
    // ============================================================

    // 50 MHz × 1 ms = 50 000个时钟。
    localparam integer ADC_SETTLE_CYCLES = 50_000;

    // 50 MHz × 10 ms = 500 000个采样点。
    localparam integer ADC_CALIBRATION_CYCLES = 500_000;

    // 50 MHz × 2 s = 100 000 000个时钟。
    localparam integer FREQUENCY_GATE_CYCLES = 100_000_000;


    // 把异步频率选择开关同步到50 MHz域，并用last检测切换事件。
    reg [2:0] freq_sel_50m_meta = 3'b000; // 第一级同步寄存器
    reg [2:0] freq_sel_50m_sync = 3'b000; // 第二级同步稳定值
    reg [2:0] freq_sel_50m_last = 3'b000; // 上一次已处理的选择码


    // 自动校准计数器与幅度统计寄存器。
    reg [15:0] adc_settle_count      = 16'd0; // 1 ms稳定等待计数
    reg [18:0] adc_calibration_count = 19'd0; // 10 ms校准窗口计数

    reg [9:0] adc_minimum  = 10'd1023; // 校准期间的最小ADC码
    reg [9:0] adc_maximum  = 10'd0;    // 校准期间的最大ADC码
    reg [9:0] adc_midpoint = 10'd512;  // M=(max+min)/2

    // 未校准时先以512为中心设置±4个码，校准完成后自动覆盖。
    reg [9:0] adc_threshold_low  = 10'd508;
    reg [9:0] adc_threshold_high = 10'd516;

    reg calibration_done = 1'b0; // 为1表示信号有效且门限已经计算完成


    // 迟滞穿越检测器与两秒门计数器。
    reg        adc_signal_high      = 1'b0; // 1表示已经越过高门限
    reg        adc_rising_pulse     = 1'b0; // 一次有效穿越产生一个20 ns脉冲
    reg [26:0] frequency_gate_count = 27'd0; // 两秒门时间计数
    reg [31:0] waveform_cycle_count = 32'd0; // 门内有效穿越次数
    reg [31:0] measured_frequency   = 32'd0; // 测频结果，单位Hz
    reg        measurement_update_toggle = 1'b0; // 新结果完成时翻转通知显示域


    // 把当前样本也纳入min/max候选值，避免校准最后一拍因非阻塞赋值
    // 仍读取旧寄存器而漏掉最后一个采样点。
    wire [9:0] adc_minimum_next =
        (adc_sample < adc_minimum)
        ? adc_sample
        : adc_minimum;

    wire [9:0] adc_maximum_next =
        (adc_sample > adc_maximum)
        ? adc_sample
        : adc_maximum;

    // R=max-min，表示观测到的峰峰值，单位为ADC码。
    wire [9:0] adc_range_next =
        adc_maximum_next - adc_minimum_next;

    // 两个10位数相加可能需要11位，随后右移一位得到中点M。
    wire [10:0] adc_sum_next =
        {1'b0, adc_minimum_next} +
        {1'b0, adc_maximum_next};

    wire [9:0] adc_midpoint_next =
        adc_sum_next[10:1];


    // 迟滞半宽H取R/8；右移3位就是除以8。
    wire [9:0] adc_hysteresis_raw =
        adc_range_next >> 3;

    // H至少为4个ADC码，因此高低门限最小间隔为8个码。
    wire [9:0] adc_hysteresis_next =
        (adc_hysteresis_raw < 10'd4)
        ? 10'd4
        : adc_hysteresis_raw;


    // 校准完成、当前处于低状态且样本达到高门限时，产生一次上升穿越。
    // 之后必须先回落到低门限才会重新触发，因此每周期只计一次。
    wire adc_rising_crossing_now =
        calibration_done &&                    // 门限已经有效
        !adc_signal_high &&                    // 检测器仍处于低状态
        (adc_sample >= adc_threshold_high);    // 当前样本达到高门限


    always @(posedge clk_50m) begin
        // 两级同步异步拨码开关。
        freq_sel_50m_meta <= freq_sel;
        freq_sel_50m_sync <= freq_sel_50m_meta;

        // 默认清零；检测到穿越时才在本周期重新置1，形成20 ns单周期脉冲。
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
            // 频率开关变化后，旧波形的门限和计数不再适用，重新校准。
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

            // 清零测量值并翻转通知，使显示域在新结果完成前先显示0。
            measurement_update_toggle <=
                ~measurement_update_toggle;

        end else if (adc_settle_count <
                     ADC_SETTLE_CYCLES - 1) begin
            // 阶段1：等待1 ms，让新模拟波形稳定。
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
            // 阶段2：连续10 ms统计ADC最小值和最大值。
            adc_minimum <= adc_minimum_next;
            adc_maximum <= adc_maximum_next;

            if (adc_calibration_count ==
                ADC_CALIBRATION_CYCLES - 1) begin

                adc_calibration_count <= 19'd0;

                // R至少为32个ADC码才认为存在可用信号；否则重新校准。
                if (adc_range_next >= 10'd32) begin
                    adc_midpoint <= adc_midpoint_next;

                    // low=M-H，high=M+H，其中H=max(R/8,4)。
                    adc_threshold_low <=
                        adc_midpoint_next -
                        adc_hysteresis_next;

                    adc_threshold_high <=
                        adc_midpoint_next +
                        adc_hysteresis_next;

                    calibration_done <= 1'b1; // 下一周期进入正式测频
                    adc_signal_high  <= 1'b0;

                    frequency_gate_count <= 27'd0;
                    waveform_cycle_count <= 32'd0;
                end else begin
                    // 信号缺失或幅度过小：清空极值并重复校准。
                    adc_minimum <= 10'd1023;
                    adc_maximum <= 10'd0;

                    calibration_done <= 1'b0;
                end

            end else begin
                adc_calibration_count <=
                    adc_calibration_count + 19'd1;
            end

        end else begin
            // 阶段3：类似施密特触发器的迟滞上升穿越检测。
            if (adc_rising_crossing_now) begin
                adc_signal_high  <= 1'b1; // 锁定高状态，防止高门限附近重复触发
                adc_rising_pulse <= 1'b1; // 输出一个50 MHz周期的事件脉冲
            end else if (adc_signal_high &&
                         (adc_sample <=
                          adc_threshold_low)) begin
                adc_signal_high <= 1'b0; // 回到低门限后重新武装
            end

            // 阶段4：在2 s固定门时间内直接统计上升穿越次数。
            if (frequency_gate_count ==
                FREQUENCY_GATE_CYCLES - 1) begin

                frequency_gate_count <= 27'd0;

                // 把门结束当前拍的穿越直接加入，固定加1用于除以2前四舍五入，
                // 右移一位等价于除以2，最终结果单位为Hz。
                measured_frequency <=
                    (waveform_cycle_count +
                     (adc_rising_crossing_now
                      ? 32'd1
                      : 32'd0) +
                     32'd1) >> 1;

                // 每个完整结果翻转一次，供100 MHz显示域可靠检测更新事件。
                measurement_update_toggle <=
                    ~measurement_update_toggle;

                waveform_cycle_count <= 32'd0;

            end else begin
                frequency_gate_count <=
                    frequency_gate_count + 27'd1;

                if (adc_rising_crossing_now) begin
                    // 每个正弦周期只应在这里累加一次。
                    waveform_cycle_count <=
                        waveform_cycle_count + 32'd1;
                end
            end
        end
    end


    // ============================================================
    // 任务三 ILA 调试探针
    //
    // PROBE0：10 位原始 ADC 采样码，可设为 Analog 观察数字采样波形；
    // PROBE1：10 位自动计算得到的 ADC 波形中点；
    // PROBE2：1 位、仅持续一个 clk_adc 周期的上升穿越脉冲；
    // PROBE3：32 位测频结果，单位为 Hz；
    // PROBE4：1 位校准完成标志。
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
    // 把 50 MHz 测频时钟域中的测量结果传递到 100 MHz 显示时钟域。
    //
    // 任务三结果从50 MHz测频域跨到100 MHz显示域。
    // measured_frequency在两次测量之间保持不变；update toggle每得到一个
    // 完整结果翻转一次，显示域检测翻转后才装载数据，避免八位数字不一致。
    // ============================================================
    reg        display_mode_meta = 1'b0;
    reg        display_mode_sync = 1'b0;

    reg [31:0] measured_frequency_meta = 32'd0; // 频率数据跨域第一级寄存
    reg [31:0] measured_frequency_sync = 32'd0; // 显示域使用的稳定频率值

    reg measurement_update_meta = 1'b0; // 翻转通知第一级同步
    reg measurement_update_sync = 1'b0; // 翻转通知第二级同步
    reg measurement_update_last = 1'b0; // 上一拍同步值，用于检测变化


    // ============================================================
    // 任务三显示：32位二进制频率转八位BCD。
    // bcd_shift左32位为8个BCD四位组，右32位为待转换二进制数。
    // 每轮先给所有≥5的BCD组分别加3，再整体左移1位；重复32轮。
    // 100 MHz下总耗时320 ns，远小于2 s测量更新周期。
    // ============================================================
    reg [63:0] bcd_shift     = 64'd0; // 左侧BCD工作区，右侧二进制输入
    reg [5:0]  bcd_iteration = 6'd0;  // 0～31，共32轮
    reg        bcd_busy      = 1'b0;  // 转换进行标志
    reg [31:0] display_bcd   = 32'd0; // 八个可直接显示的BCD数字

    reg [63:0] bcd_adjusted;
    integer bcd_digit_index;

    always @(*) begin
        bcd_adjusted = bcd_shift; // 默认保持原值

        for (bcd_digit_index = 0;
             bcd_digit_index < 8;
             bcd_digit_index = bcd_digit_index + 1) begin

            // 每一个4位BCD组单独判断，满足≥5时只给该组加3。
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
    // 整体左移时，二进制最高位逐步进入BCD工作区，最右端补0。
    assign bcd_shift_next = bcd_adjusted << 1;


    always @(posedge clk_in) begin
        // 两级同步物理显示模式开关，降低异步输入的亚稳态传播风险。
        display_mode_meta <= display_mode;
        display_mode_sync <= display_mode_meta;

        // 同步长期稳定的32位频率结果总线。
        measured_frequency_meta <= measured_frequency;
        measured_frequency_sync <= measured_frequency_meta;

        // 同步翻转通知，并通过sync与last不同检测一个新结果事件。
        measurement_update_meta <= measurement_update_toggle;
        measurement_update_sync <= measurement_update_meta;
        measurement_update_last <= measurement_update_sync;

        if (measurement_update_sync !=
            measurement_update_last) begin

            // 左侧BCD工作区清零，右侧装入新的二进制Hz值。
            bcd_shift <= {
                32'd0,
                measured_frequency_sync
            };

            bcd_iteration <= 6'd0;
            bcd_busy      <= 1'b1;

        end else if (bcd_busy) begin
            // 每个100 MHz时钟完成一轮“加3后左移”。
            bcd_shift <= bcd_shift_next;

            if (bcd_iteration == 6'd31) begin
                // 保存next值以包含第32轮的最后一次移位结果。
                display_bcd <= bcd_shift_next[63:32];
                bcd_busy    <= 1'b0;
            end else begin
                bcd_iteration <= bcd_iteration + 6'd1;
            end
        end
    end


    // ============================================================
    // 八位数码管动态扫描
    //
    // display_mode = 0：显示学号 20051121；
    // display_mode = 1：显示任务三测得的频率，单位为 Hz。
    //
    // 频率占用全部八位，不足的高位补 0：
    //       1 kHz -> 00001000
    //      10 kHz -> 00010000
    //      50 kHz -> 00050000
    //       1 MHz -> 01000000
    //     1.5 MHz -> 01500000
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


    // 根据当前扫描位置选择要点亮的十进制数字。
    always @(*) begin
        if (!display_mode_sync) begin
            // 学号显示：20051121。
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
            // 任务三频率显示：BCD 的每四位对应一位十进制数。
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


    // 段选为高电平点亮，位序为 {dp, g, f, e, d, c, b, a}。
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


    // 切换位选时先短暂熄灭所有段，减轻相邻数码管之间的重影。
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
