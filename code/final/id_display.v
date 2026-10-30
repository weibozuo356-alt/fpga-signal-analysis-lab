`timescale 1ns / 1ps
// 仿真时间单位为1 ns，时间精度为1 ps。

module id_display #(
    // 任务一数码管动态扫描参数：
    // 在100 MHz时钟下，每计满50 000个时钟切换到下一位。
    // 单位显示时间为50 000 × 10 ns = 0.5 ms，
    // 八位完整扫描一轮为4 ms，理论整屏刷新率为250 Hz。
    parameter integer SCAN_CYCLES = 50_000
)(
    // 板载100 MHz系统时钟，也是任务一显示扫描逻辑的工作时钟。
    input  wire        clk_in,
    // 任务二频率选择开关，三位选择码按{SW2,SW1,SW0}读取：
    // 000→1 kHz，001→10 kHz，010→50 kHz，011→1 MHz，
    // 100→1.5 MHz，101→2 MHz；110和111的DDS仍默认输出1 kHz。
    // 当选择111且处于频率显示模式时，数码管改为显示DDS理论频率分辨率。
    input  wire [2:0]  freq_sel,
    // 显示模式选择：同步后的值为0时显示任务一ID 20051121；
    // 值为1时显示后续任务的频率或THD测量结果。
    input  wire        display_mode,
    input  wire        thd_display_select,

    // ============================================================
    // 任务二：外接14位DAC接口
    // dac_clk：送给外接DAC的10 MHz采样时钟。
    // dac_data：送给DAC的14位偏移二进制幅度码，仍然是数字量；
    //           DAC收到该数字码后才将其转换成连续的模拟电压。
    // ============================================================
    output wire        dac_clk,
    output wire [13:0] dac_data,

    // ============================================================
    // 任务三：外接10位ADC接口
    // ad_in：ADC已经量化完成的10位并行幅度码，范围为0～1023；
    //        它表示当前采样时刻的模拟电压，不是FPGA计算出的门限值。
    // clk_ad：送给外部ADC的50 MHz采样时钟，周期为20 ns。
    // adc_clamp：ADC钳位功能控制，本工程固定为0以关闭钳位。
    // ============================================================
    input  wire [9:0]  ad_in,
    output wire        clk_ad,
    output wire        adc_clamp,

    // ============================================================
    // 任务一：八位七段数码管接口
    // seg_cs_pin：8位独热位选，决定当前点亮哪一位数码管。
    // seg_data_0_pin：向第0～3位所在的段线组发送段码。
    // seg_data_1_pin：向第4～7位所在的段线组发送段码。
    // 每组段码位序均为{dp, g, f, e, d, c, b, a}，高电平点亮。
    // ============================================================
    output reg  [7:0]  seg_cs_pin,
    output reg  [7:0]  seg_data_0_pin,
    output reg  [7:0]  seg_data_1_pin
);


    // ============================================================
    // 任务二时钟生成：把板载100 MHz时钟转换为10 MHz和50 MHz
    //
    // clk_10m：任务二DDS和DAC的采样时钟，周期为100 ns；
    //          每来一个上升沿，DDS产生一个新的正弦幅度样本。
    // clk_50m：供后续ADC、测频和FFT任务使用，任务二产生正弦波时
    //          主要关注clk_10m。
    // clk_10m_locked：Clock Wizard锁定标志；为1表示输出时钟已经稳定。
    // ============================================================
    wire clk_10m;
    wire clk_50m;
    wire clk_10m_locked;

    clk_wiz_10m u_clk_wiz_10m (
        .clk_out1 (clk_10m),        // 第1路输出：10 MHz，供DDS和DAC使用
        .clk_out2 (clk_50m),        // 第2路输出：50 MHz，供后续ADC等逻辑使用
        .reset    (1'b0),           // 始终不复位Clock Wizard
        .locked   (clk_10m_locked), // 输出时钟稳定后该信号变为1
        .clk_in1  (clk_in)          // 输入板载100 MHz系统时钟
    );


    // ============================================================
    // 任务三：ADC钳位控制
    // adc_clamp保持低电平，关闭外接ADC板上的钳位功能。
    // 该信号不是ADC复位，也不决定采样频率。
    // ============================================================
    assign adc_clamp = 1'b0;


    // ============================================================
    // 任务三：使用ODDR向外接ADC转发50 MHz采样时钟
    // clk_50m的周期为20 ns，因此ADC理论上每20 ns更新一次10位采样码。
    // 这里的20 ns是采样间隔，不是被测正弦波的周期。
    // ============================================================
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_adc_clk_oddr (
        .Q  (clk_ad),          // 输出到外部ADC的采样时钟引脚
        .C  (clk_50m),         // 内部50 MHz时钟
        .CE (clk_10m_locked),  // Clock Wizard锁定后才允许输出时钟
        .D1 (1'b1),            // 内部时钟上升沿后输出1
        .D2 (1'b0),            // 内部时钟下降沿后输出0
        .R  (1'b0),            // 不使用复位
        .S  (1'b0)             // 不使用置位
    );


    // ============================================================
    // 任务二：DDS频率控制字
    //
    // DDS内部使用32位相位累加器。每个10 MHz采样时钟上升沿，
    // 相位累加器都增加一次控制字K；K越大，相位绕一圈越快，
    // 因而输出正弦波的频率越高。
    //
    // 输出频率公式：f_out = K × f_s / 2^32
    // 控制字公式：    K = round(f_out × 2^32 / f_s)
    // 本工程f_s = 10 MHz，因此理论频率分辨率为：
    // Δf = 10 MHz / 2^32 ≈ 0.002328306 Hz。
    // ============================================================
    localparam [31:0] K_1KHZ   = 32'd429497;    // 约产生1 kHz
    localparam [31:0] K_10KHZ  = 32'd4294967;   // 约产生10 kHz
    localparam [31:0] K_50KHZ  = 32'd21474836;  // 约产生50 kHz
    localparam [31:0] K_1MHZ   = 32'd429496730; // 约产生1 MHz
    localparam [31:0] K_1P5MHZ = 32'd644245094; // 约产生1.5 MHz
    localparam [31:0] K_2MHZ   = 32'd858993459; // 约产生2 MHz

    // 10 MHz / 2^32 = 0.002328306... Hz。
    // 八位数码管最多显示七位小数，因此把Hz值放大10^7并四舍五入：
    // 0.002328306... × 10^7 ≈ 23283，配合最左位小数点显示0.0023283。
    localparam [31:0] DDS_RESOLUTION_DISPLAY_VALUE = 32'd23283;


    // 根据同步后的三位拨码选择码，返回对应的32位频率控制字。
    // function描述的是组合逻辑，不会单独形成时钟寄存器。
    function [31:0] select_frequency_word;
        input [2:0] select; // 三位频率选择码

        begin
            case (select)
                3'b000: select_frequency_word = K_1KHZ;   // SW2~SW0=000：1 kHz
                3'b001: select_frequency_word = K_10KHZ;  // SW2~SW0=001：10 kHz
                3'b010: select_frequency_word = K_50KHZ;  // SW2~SW0=010：50 kHz
                3'b011: select_frequency_word = K_1MHZ;   // SW2~SW0=011：1 MHz
                3'b100: select_frequency_word = K_1P5MHZ; // SW2~SW0=100：1.5 MHz
                3'b101: select_frequency_word = K_2MHZ;   // SW2~SW0=101：2 MHz

                // 110和111没有分配新的DDS输出频点，仍输出默认1 kHz；
                // 111的0.0023283 Hz只属于数码管信息显示，不改变DDS输出。
                default: select_frequency_word = K_1KHZ;
            endcase
        end
    endfunction


    // ============================================================
    // 任务二：把异步拨码开关同步到10 MHz DDS时钟域
    //
    // 物理拨码开关可能在任意时刻变化，并不与clk_10m对齐。
    // freq_sel_meta和freq_sel_sync构成两级同步器，用于降低亚稳态
    // 直接传播到DDS配置逻辑的风险。
    // ============================================================
    reg [2:0] freq_sel_meta = 3'b000; // 第一级同步寄存器
    reg [2:0] freq_sel_sync = 3'b000; // 第二级同步后的稳定选择码
    reg [2:0] freq_sel_last = 3'b000; // 记录上一次已经发送给DDS的选择码

    reg        dds_config_sent  = 1'b0;   // 是否至少完成过一次DDS配置
    reg [31:0] dds_config_data  = K_1KHZ; // 送入DDS的32位频率控制字K
    reg        dds_config_valid = 1'b0;   // 配置有效脉冲，高电平只保持一个周期

    always @(posedge clk_10m) begin
        // 第一级在本拍采集外部开关，第二级取得第一级的上一拍值。
        // 非阻塞赋值<=在判断时使用旧值，并在时钟沿后统一更新。
        freq_sel_meta <= freq_sel;
        freq_sel_sync <= freq_sel_meta;

        // 每拍先默认拉低；只有首次配置或开关改变时，下面才重新置1。
        // 因此dds_config_valid最终形成宽度为一个10 MHz周期的脉冲。
        dds_config_valid <= 1'b0;

        if (!clk_10m_locked) begin
            // 时钟尚未稳定时不向DDS发送配置，并清除“已发送”标志。
            dds_config_sent <= 1'b0;
        end
        else if (!dds_config_sent ||
                     (freq_sel_sync != freq_sel_last)) begin

            // 首次启动，或者同步后的选择码与上次不同，就发送新控制字。
            freq_sel_last    <= freq_sel_sync; // 保存本次选择码，供后续比较
            dds_config_data  <=
                select_frequency_word(freq_sel_sync); // 查出对应K值
            dds_config_valid <= 1'b1; // 通知DDS：本周期配置数据有效
            dds_config_sent  <= 1'b1; // 标记已经完成一次配置发送
        end
    end


    // ============================================================
    // 任务二：DDS Compiler正弦信号发生器
    //
    // DDS内部完成“32位相位累加 → 正弦查表/计算 → 16位幅度输出”。
    // 32位相位描述当前位于正弦周期的哪个位置，决定频率分辨率；
    // 16位dds_data描述该相位对应的瞬时正弦幅度，两者不是同一种数据。
    // ============================================================
    wire               dds_valid; // 为1表示本周期dds_data是有效的新样本
    wire signed [15:0] dds_data;  // DDS输出的16位二进制补码正弦幅度

    dds_sine u_dds_sine (
        .aclk                 (clk_10m),          // DDS采样时钟：10 MHz
        .s_axis_config_tvalid (dds_config_valid), // 配置字有效脉冲
        .s_axis_config_tdata  (dds_config_data),  // 32位频率控制字K
        .m_axis_data_tvalid   (dds_valid),        // 正弦样本有效指示
        .m_axis_data_tdata    (dds_data)          // 16位有符号正弦幅度样本
    );


    // ============================================================
    // 任务二：把DDS的16位有符号补码转换成DAC的14位偏移二进制
    //
    // DDS输出范围约为-32768～32767，零幅度的补码为16'h0000；
    // DAC输入范围为0～16383，零幅度应位于中点14'd8192=14'h2000。
    // 转换方法：丢弃最低2位，使16位幅度缩减为14位；
    //           再翻转原符号位，把补码转换成偏移二进制。
    // 注意：dac_data仍是数字码，经过外部DAC后才变成模拟电压。
    // ============================================================
    reg [13:0] dac_data_reg = 14'h2000; // 初始为DAC中点码，对应零幅度

    always @(posedge clk_10m) begin
        if (!clk_10m_locked) begin
            // 时钟未稳定时保持中点码，避免DAC输出不确定的大幅跳变。
            dac_data_reg <= 14'h2000;
        end
         else if (dds_valid) begin
            // {翻转16位符号位, 保留第14～2位}，共组成14位DAC数据。
            // 负峰附近→接近0，零幅度→8192，正峰附近→接近16383。
            dac_data_reg <= { ~dds_data[15], dds_data[14:2] };
        end
    end

    assign dac_data = dac_data_reg; // 将寄存后的14位数字码送到顶层DAC引脚


    // ============================================================
    // 任务二：使用ODDR向外接DAC转发10 MHz采样时钟
    //
    // dac_data_reg在clk_10m上升沿更新；ODDR设置D1=0、D2=1，
    // 使外部dac_clk在内部clk_10m下降沿上升。10 MHz半周期为50 ns，
    // 因而DAC采样沿比数据更新沿晚50 ns，给并行数据留出稳定时间。
    // ============================================================
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"), // D1和D2按同一上升沿关系装入
        .INIT         (1'b0),        // FPGA配置完成后输出初始值为0
        .SRTYPE       ("SYNC")       // 置位/复位采用同步方式
    ) u_dac_clk_oddr (
        .Q  (dac_clk), // ODDR输出，连接外部DAC采样时钟引脚
        .C  (clk_10m), // 内部10 MHz时钟
        .CE (1'b1),    // 时钟使能始终有效
        .D1 (1'b0),    // 内部时钟上升沿后输出0
        .D2 (1'b1),    // 内部时钟下降沿后输出1
        .R  (1'b0),    // 不使用复位
        .S  (1'b0)     // 不使用置位
    );


    // ============================================================
    // 任务三：在50 MHz时钟域采入外部ADC的10位并行结果
    // ad_in由ADC根据模拟输入电压直接量化产生；例如ad_in=650表示
    // 当前采样码为650，并不是FPGA用门限公式计算出了650。
    // ============================================================
    reg [9:0] adc_sample = 10'd0; // FPGA内部保存的当前ADC样本，范围0～1023

    always @(posedge clk_50m) begin
        if (!clk_10m_locked) begin
            adc_sample <= 10'd0; // 时钟尚未锁定时先保持为0
        end
        else begin
            adc_sample <= ad_in; // 每个50 MHz上升沿锁存一个新的10位ADC码
        end
    end


    // ============================================================
    // 任务三核心：ADC自动校准与正弦信号频率测量
    //
    // 上电或频率选择开关改变后，依次执行：
    // 1. 等待1 ms，让DDS、DAC和模拟回环中的新波形稳定；
    // 2. 连续采样10 ms，记录ADC最小码和最大码；
    // 3. 由min/max计算中点M、幅度范围R和高低迟滞门限；
    // 4. 波形从低状态越过高门限时产生一个20 ns事件脉冲，
    //    回落到低门限后才重新允许触发，从而每周期只计一次；
    // 5. 在固定2 s门时间内累计穿越次数，再除以2得到频率Hz。
    // ============================================================

    // 50 MHz × 1 ms = 50 000个时钟，用于切换频率后的稳定等待。
    localparam integer ADC_SETTLE_CYCLES = 50_000;

    // 50 MHz × 10 ms = 500 000个样本，用于统计波形最小值和最大值。
    localparam integer ADC_CALIBRATION_CYCLES = 500_000;

    // 50 MHz × 2 s = 100 000 000个时钟，即一次完整测频门时间。
    localparam integer FREQUENCY_GATE_CYCLES = 100_000_000;


    // 把异步拨码开关同步到50 MHz ADC时钟域。
    // meta为第一级同步寄存器，sync为第二级稳定值，last保存上一次值，
    // 便于检测用户是否切换了频率；切换后必须重新校准和重新测量。
    reg [2:0] freq_sel_50m_meta = 3'b000; // 第一级同步，可能承受亚稳态
    reg [2:0] freq_sel_50m_sync = 3'b000; // 第二级同步，供后续逻辑使用
    reg [2:0] freq_sel_50m_last = 3'b000; // 上一次已经处理的选择码


    // 自动校准所需的计数器和统计寄存器。
    reg [15:0] adc_settle_count      = 16'd0; // 1 ms稳定等待计数
    reg [18:0] adc_calibration_count = 19'd0; // 10 ms校准窗口计数

    reg [9:0] adc_minimum  = 10'd1023; // 校准窗口中观测到的最小ADC码
    reg [9:0] adc_maximum  = 10'd0;    // 校准窗口中观测到的最大ADC码
    reg [9:0] adc_midpoint = 10'd512;  // (最大值+最小值)/2，近似直流中心

    // 初始门限以512为中心，上下各相差4个ADC码；
    // 校准完成后会被实际min/max计算出的门限覆盖。
    reg [9:0] adc_threshold_low  = 10'd508;
    reg [9:0] adc_threshold_high = 10'd516;

    reg calibration_done = 1'b0; // 为1表示当前波形幅度有效且门限已经算好

    // 把0～1023的无符号ADC码减去自动测得的中点，得到以0为中心的有符号量。
    // 该信号主要供后续任务四、五FFT使用；任务三测频仍直接使用adc_sample。
    wire signed [10:0] adc_centered;

    assign adc_centered =
    $signed({1'b0, adc_sample}) -
    $signed({1'b0, adc_midpoint});


    // 迟滞穿越检测器和两秒频率计数器。
    reg        adc_signal_high      = 1'b0; // 迟滞状态：1表示已越过高门限
    reg        adc_rising_pulse     = 1'b0; // 每次有效上升穿越产生一个周期的调试脉冲
    reg [26:0] frequency_gate_count = 27'd0; // 两秒门时间的50 MHz时钟计数
    reg [31:0] waveform_cycle_count = 32'd0; // 两秒内累计的有效上升穿越次数
    reg [31:0] measured_frequency   = 32'd0; // 最终测频结果，单位为Hz
    reg        measurement_update_toggle = 1'b0; // 新结果完成时翻转，通知显示域


    // ============================================================
    // 任务五：外接10～100 kHz信号的自动采样率分档
    //
    // 50%占空比方波若要把理论THD截断误差控制在3%以内，
    // 至少需要累计到第37次谐波。本设计累计到第49次谐波，
    // 给平均抽取滤波器的幅频衰减和实际硬件误差留出余量。
    //
    // 为了让10～100 kHz范围内的基波和高次谐波都能被FFT分辨，
    // 外接模式freq_sel=110按实测频率选择三档有效采样率：
    //   profile=0：f<=35 kHz，10点平均后抽取，有效Fs=5 MSPS；
    //   profile=1：35 kHz<f<=70 kHz，5点平均后抽取，有效Fs=10 MSPS；
    //   profile=2：f>70 kHz，不抽取，有效Fs=50 MSPS。
    // ============================================================
    reg [1:0] thd_auto_rate_profile;

    always @(*) begin
        if (freq_sel_50m_sync != 3'b110)
            thd_auto_rate_profile = 2'd0; // 固定档位不使用任务五分档
        else if (measured_frequency > 32'd70000)
            thd_auto_rate_profile = 2'd2; // 70～100 kHz：保留50 MSPS
        else if (measured_frequency > 32'd35000)
            thd_auto_rate_profile = 2'd1; // 35～70 kHz：有效10 MSPS
        else
            thd_auto_rate_profile = 2'd0; // 10～35 kHz：有效5 MSPS
    end


    // 组合逻辑先把“当前adc_sample”也纳入min/max候选结果。
    // 这样在校准窗口最后一个时钟沿，计算门限时不会因为非阻塞赋值
    // 仍在读取旧adc_minimum/adc_maximum而漏掉最后一个样本。
    wire [9:0] adc_minimum_next =
        (adc_sample < adc_minimum) ? adc_sample : adc_minimum;

    wire [9:0] adc_maximum_next =
        (adc_sample > adc_maximum) ? adc_sample : adc_maximum;

    // R=max-min，表示本次校准观测到的峰峰值，单位为ADC码。
    wire [9:0] adc_range_next =
        adc_maximum_next - adc_minimum_next;

    // 最大值与最小值相加可能需要11位，不能仍用10位保存。
    wire [10:0] adc_sum_next =
        {1'b0, adc_minimum_next} +
        {1'b0, adc_maximum_next};

    // 右移一位等价于除以2，得到M=(max+min)/2。
    wire [9:0] adc_midpoint_next = adc_sum_next[10:1];


    // 迟滞半宽H取幅度范围R的1/8；右移3位即除以8。
    wire [9:0] adc_hysteresis_raw = adc_range_next >> 3;

    // 若R/8小于4，则至少保留4个ADC码的迟滞半宽。
    // 因而高低门限最小间隔为8个码，可降低门限附近噪声造成的重复计数。
    wire [9:0] adc_hysteresis_next =
        (adc_hysteresis_raw < 10'd4)
        ? 10'd4
        : adc_hysteresis_raw;


    // 当前处于低状态、校准完成且样本达到高门限时，判定一次上升穿越。
    // adc_signal_high随后置1，在样本回落到低门限前不会再次触发，
    // 因此理想正弦波每个周期只产生一次有效穿越事件。
    wire adc_rising_crossing_now =
        calibration_done &&                    // 门限已经由有效波形校准完成
        !adc_signal_high &&                    // 当前检测器处于低状态
        (adc_sample >= adc_threshold_high);    // 当前样本达到或超过高门限


    always @(posedge clk_50m) begin
        // 两级同步异步拨码开关。当前时钟沿判断使用同步寄存器的旧值。
        freq_sel_50m_meta <= freq_sel;
        freq_sel_50m_sync <= freq_sel_50m_meta;

        // 默认清零；只有本周期真正检测到上升穿越时，后面才重新置1。
        // 所以adc_rising_pulse宽度恰好为一个50 MHz周期，即约20 ns。
        adc_rising_pulse <= 1'b0;

        if (!clk_10m_locked) begin
            // Clock Wizard尚未锁定：所有校准、穿越和计数状态回到初值。
            freq_sel_50m_last <= 3'b000;

            adc_settle_count      <= 16'd0;
            adc_calibration_count <= 19'd0;

            adc_minimum  <= 10'd1023; // min从最大可能码开始，便于逐步减小
            adc_maximum  <= 10'd0;    // max从最小可能码开始，便于逐步增大
            adc_midpoint <= 10'd512;

            adc_threshold_low  <= 10'd508; // 尚未校准时的安全初值
            adc_threshold_high <= 10'd516;

            calibration_done <= 1'b0;
            adc_signal_high  <= 1'b0;

            frequency_gate_count <= 27'd0;
            waveform_cycle_count <= 32'd0;
            measured_frequency   <= 32'd0;
            measurement_update_toggle <= 1'b0;

        end else if (freq_sel_50m_sync !=
                     freq_sel_50m_last) begin
            // 发现频率选择开关变化：任务二将产生新频率，任务三必须清空
            // 上一次波形的门限和计数结果，从稳定等待阶段重新开始。
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

            // measured_frequency已经清零；同时翻转通知信号，让100 MHz显示域
            // 立刻把数码管更新为0，避免新结果尚未完成时仍显示旧频率。
            measurement_update_toggle <=
                ~measurement_update_toggle;

        end else if (adc_settle_count <
                     ADC_SETTLE_CYCLES - 1) begin
            // 阶段1：等待1 ms，让DDS配置、DAC输出和模拟回环中的新波形稳定。
            adc_settle_count <=
                adc_settle_count + 16'd1;

            adc_calibration_count <= 19'd0;
            // 等待期间不采集幅度极值，始终准备好校准初值。
            adc_minimum <= 10'd1023;
            adc_maximum <= 10'd0;

            calibration_done <= 1'b0;
            adc_signal_high  <= 1'b0;

            frequency_gate_count <= 27'd0;
            waveform_cycle_count <= 32'd0;

        end else if (!calibration_done) begin
            // 阶段2：在10 ms校准窗口内不断更新ADC最小值和最大值。
            adc_minimum <= adc_minimum_next;
            adc_maximum <= adc_maximum_next;

            if (adc_calibration_count ==
                ADC_CALIBRATION_CYCLES - 1) begin

                adc_calibration_count <= 19'd0;

                // 10 ms窗口结束后先检查R=max-min是否至少为32个ADC码。
                // 若小于32，可能是SMA未连接、信号缺失或幅度过小，不进入测频。
                if (adc_range_next >= 10'd32) begin
                    adc_midpoint <= adc_midpoint_next;

                    // 低门限=M-H，高门限=M+H，其中H=max(R/8,4)。
                    adc_threshold_low <=
                        adc_midpoint_next -
                        adc_hysteresis_next;

                    adc_threshold_high <=
                        adc_midpoint_next +
                        adc_hysteresis_next;

                    calibration_done <= 1'b1; // 门限有效，下周期进入正式测频
                    adc_signal_high  <= 1'b0; // 从低状态开始等待第一次上升穿越

                    frequency_gate_count <= 27'd0;
                    waveform_cycle_count <= 32'd0;
                end else begin
                    // 未检测到有效幅度：重置min/max，下一轮继续自动校准。
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
                adc_signal_high  <= 1'b1; // 锁定为高状态，防止高门限附近重复触发
                adc_rising_pulse <= 1'b1; // 输出一个20 ns调试/计数事件脉冲
            end
             else if (adc_signal_high &&
                         (adc_sample <=
 adc_threshold_low)) begin
                // 波形必须真正回落到低门限，检测器才重新武装。
                adc_signal_high <= 1'b0;
            end

            // 阶段4：两秒直接计数法。
            // 两秒内每个正弦周期产生一次上升穿越，累计数N除以2即为Hz。
            if (frequency_gate_count ==
                FREQUENCY_GATE_CYCLES - 1) begin

                frequency_gate_count <= 27'd0;

                // 非阻塞赋值在当前时钟沿判断时仍读取旧waveform_cycle_count，
                // 因而要用adc_rising_crossing_now把“门结束这一拍”的事件直接加上。
                // 再固定加1完成整数除以2前的四舍五入，右移1位即除以2。
                measured_frequency <=
(waveform_cycle_count + (adc_rising_crossing_now ? 32'd1 : 32'd0) + 32'd1) >> 1;

                // 每得到一个完整频率结果就翻转一次；跨时钟域时检测翻转即可，
                // 不会因单周期脉冲过窄而漏掉通知。
                measurement_update_toggle <=
                    ~measurement_update_toggle;

                waveform_cycle_count <= 32'd0;

            end else begin
                // 测量门尚未结束：每个50 MHz时钟累加一次门计数器。
                frequency_gate_count <=
                    frequency_gate_count + 27'd1;

                if (adc_rising_crossing_now) begin
                    // 每检测到一个有效上升穿越，就把周期数加1。
                    waveform_cycle_count <=
                        waveform_cycle_count + 32'd1;
                end
            end
        end
    end

// ============================================================
// 任务四、任务五共用：4096点FFT输入与输出
//
// FFT输入是复数：实部为去除直流中心后的有符号ADC样本，虚部固定为0。
// 每帧共送入4096个样本；送入FFT前先进行平均抽取，再乘Hann窗，
// 用于减小非相干采样时的频谱泄漏。FFT输出采用自然顺序0～4095。
// ============================================================


// ------------------------------------------------------------
// 任务四、任务五共用：按频率进行滑动平均与抽取
//
// ADC和FFT IP的工作时钟始终是50 MHz，只降低送入FFT的AXI有效样本速率。
// 低频档先对若干ADC样本求和并近似取平均，再每组只输出一个样本，
// 从而降低有效采样率、缩小FFT频点间隔，兼顾低频分辨率与高频带宽。
//
//   freq_sel   测量档位             平均长度       有效采样率Fs
//     000      固定1 kHz               500          100 kSPS
//     001      固定10 kHz               50            1 MSPS
//     010      固定50 kHz               10            5 MSPS
//     011      固定1 MHz                 1           50 MSPS
//     100      固定1.5 MHz               1           50 MSPS
//     101      固定2 MHz                 1           50 MSPS
//     110      外接10～35 kHz            10            5 MSPS
//              外接35～70 kHz             5           10 MSPS
//              外接70～100 kHz            1           50 MSPS
//     111      保留/默认                 500          100 kSPS
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
        3'b110: begin
            case (thd_auto_rate_profile)
                2'd2: decimation_factor = 10'd1;
                2'd1: decimation_factor = 10'd5;
                default: decimation_factor = 10'd10;
            endcase
        end
        default: decimation_factor = 10'd500;
    endcase
end


// 11位有符号ADC数据最多累加500次，因此累加器使用21位，防止求和溢出。
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


// 用算术右移近似完成除法，避免综合出通用除法器。
// 同一个比例会同时作用于基波和各次谐波，计算THD功率比时会相互抵消，
// 因此这里的近似缩放不会改变最终THD比例。
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

        // 任务五外接10～100 kHz自动测量：按profile选择抽取倍数。
        3'b110: begin
            case (thd_auto_rate_profile)
                2'd2: decimation_scaled = adc_centered_21;
                2'd1: decimation_scaled =
                    decimation_sum_next >>> 3; // approximately /5
                default: decimation_scaled =
                    decimation_sum_next >>> 4; // approximately /10
            endcase
        end

        default: decimation_scaled =
            decimation_sum_next >>> 9;
    endcase
end


wire signed [15:0] decimated_adc_sample;

assign decimated_adc_sample = decimation_scaled[15:0];


// ------------------------------------------------------------
// FFT复位控制
// Clock Wizard锁定且ADC完成幅度/中点校准之后才释放FFT复位，
// 防止启动阶段的无效样本进入频谱。aresetn为低有效复位。
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
// FFT配置通道
// s_axis_config_tdata[0]=1选择正向FFT；配置仅在复位释放后发送一次。
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
// FFT输入AXI-Stream通道
// 低16位装入有符号实部，高16位为固定0的虚部；
// 每送入第4096个样本时拉高tlast，标记一帧输入结束。
// ------------------------------------------------------------
reg [31:0] fft_input_data  = 32'd0;
reg        fft_input_valid = 1'b0;
reg        fft_input_last  = 1'b0;

wire       fft_input_ready;

reg [11:0] fft_input_index = 12'd0;


// ------------------------------------------------------------
// 4096点Hann窗
// hann_4096_q15.mem保存0～32767范围的Q1.15正系数，
// 当前FFT输入序号同时作为窗系数ROM地址，使第n个样本乘第n个窗系数。
// ROM采用异步读，便于样本与系数对齐；Vivado通常将其实现为分布式ROM。
// 加窗可抑制频谱泄漏，但会使单一频率的能量分散到相邻若干频点，
// 因而后面的基波和谐波均按“频带”而不是单个频点累计功率。
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
        // FFT接收当前样本后默认撤销tvalid；若本拍又形成新的抽取样本，
        // 下方逻辑会在同一时钟周期结束时重新置1。
        if (fft_input_valid && fft_input_ready) begin
            fft_input_valid <= 1'b0;
        end

        // 当FFT拉低tready施加背压时，保持当前样本不变，避免覆盖尚未接收的数据；
        // 这样即使通常tready持续为高，输入端也仍符合AXI-Stream握手规则。
        if (!fft_input_valid || fft_input_ready) begin
            if (decimation_factor == 10'd1) begin
                // 高频固定档或任务五profile=2使用每个ADC样本，不平均也不抽取。
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
                // decimation_sum_next已经包含当前ADC样本，本拍正好结束这一组平均。
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
                // 当前平均组尚未收满样本，继续累加并等待。
                decimation_sum <= decimation_sum_next;
                decimation_count <=
                    decimation_count + 10'd1;
            end
        end
    end
end


// ------------------------------------------------------------
// FFT输出信号
// 当前FFT采用不缩放配置，实部和虚部分别占32位：低32位为实部，
// 高32位为虚部；TUSER低12位给出当前频点序号XK_INDEX=0～4095。
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


// FFT诊断事件：用于汇总帧错误、通道停顿等异常状态。
wire fft_event_frame_started;
wire fft_event_tlast_unexpected;
wire fft_event_tlast_missing;
wire fft_event_status_channel_halt;
wire fft_event_data_in_channel_halt;
wire fft_event_data_out_channel_halt;


// ------------------------------------------------------------
// 4096点FFT IP实例
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
// 任务四、任务五共用：计算每个FFT频点的功率
// P[k]=Re[k]^2+Im[k]^2。
// FFT实部和虚部都是有符号数，先取绝对值再平方；功率、频点序号、
// valid和last同时寄存，保证后级看到的是同一个频点的一组对齐数据。
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
// 任务四、任务五：寻找基波并建立谐波功率带
// Hann窗会把一个正弦分量的能量扩展到相邻频点，因此任务四固定档
// 对每个分量累计“中心频点±2”共5个频点，而不是只取中心一点。
// 只统计正频率半区；负频率镜像包含重复信息，THD比值中不必再次加入。
//
// freq_sel=000～101属于任务四，基波频点由已知固定频率直接给出；
// freq_sel=110属于任务五，在允许搜索范围内找到功率最大的频点作为基波。
// 切换有效采样率期间放宽最低搜索频点，避免旧测频值暂时遮住新基波。
// 当前FFT帧检测出的基波位置从下一帧开始用于功率累计。
// ============================================================
wire thd_auto_mode;
assign thd_auto_mode =
    (freq_sel_50m_sync == 3'b110); // 110表示任务五外接信号自动THD模式

localparam [11:0] AUTO_SEARCH_MIN_BIN = 12'd6;
localparam [11:0] AUTO_SEARCH_MAX_BIN = 12'd84;

wire [11:0] auto_search_min_bin;
assign auto_search_min_bin =
    (thd_auto_rate_profile != 2'd0)
    ? 12'd3
    : AUTO_SEARCH_MIN_BIN;

reg [63:0] auto_search_peak_power = 64'd0;
reg [11:0] auto_search_peak_bin   = 12'd0;
reg [11:0] detected_fundamental_bin = 12'd0;
reg        detected_fundamental_valid = 1'b0;

wire auto_search_in_range;
assign auto_search_in_range =
    (fft_power_index >= auto_search_min_bin) &&
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
        // 任务四低频三档经过各自抽取后，基波都落在约40.96号频点附近。
        3'b000,
        3'b001,
        3'b010: begin
            thd_bin_1 = 12'd41;
            thd_bin_2 = 12'd82;
            thd_bin_3 = 12'd123;
            thd_bin_4 = 12'd164;
            thd_bin_5 = 12'd205;
        end

        // 任务四固定1 MHz档，有效采样率50 MSPS。
        3'b011: begin
            thd_bin_1 = 12'd82;
            thd_bin_2 = 12'd164;
            thd_bin_3 = 12'd246;
            thd_bin_4 = 12'd328;
            thd_bin_5 = 12'd410;
        end

        // 任务四固定1.5 MHz档，有效采样率50 MSPS。
        3'b100: begin
            thd_bin_1 = 12'd123;
            thd_bin_2 = 12'd246;
            thd_bin_3 = 12'd369;
            thd_bin_4 = 12'd492;
            thd_bin_5 = 12'd614;
        end

        // 任务四固定2 MHz档，有效采样率50 MSPS。
        3'b101: begin
            thd_bin_1 = 12'd164;
            thd_bin_2 = 12'd328;
            thd_bin_3 = 12'd492;
            thd_bin_4 = 12'd655;
            thd_bin_5 = 12'd819;
        end

        // 任务五：外接10～100 kHz未知信号，使用自动检测到的基波频点。
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

// 任务四已知频点使用中心±2的5点频带。
// 任务五的thd_bin_1仍用于累计基波；其高次谐波另由后面的Q12精确中心
// 和±3点频带判断，不再用整数基波频点简单相乘，避免高次谐波中心漂移。
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

// 任务五严格THD：只累计整数倍谐波H2～H49附近的窄频带。
// 如果把基波之外的所有频点都放入分子，算出的会是THD+N（总谐波失真加噪声），
// 小幅度输入时宽带噪声会被大量计入，从而出现三角波、方波THD严重偏大的问题。
localparam integer AUTO_HIGHEST_HARMONIC = 49; // 最高累计到第49次谐波
localparam [27:0] AUTO_HARMONIC_HALF_WIDTH_Q12 = 28'd12288; // 12288=3个FFT频点(Q12)

// 把独立测频结果换算为带12位小数的FFT频点位置：
//   bin_q12 = 频率 × 4096点 × 2^12 / 有效采样率。
// 使用预先计算的Q20比例常数完成换算，避免在FPGA中综合通用除法器。
reg [21:0] auto_bin_scale_q20;

always @(*) begin
    case (thd_auto_rate_profile)
        // profile=2：有效采样率50 MSPS。
        2'd2: auto_bin_scale_q20 = 22'd351844;

        // profile=1：有效采样率10 MSPS。
        2'd1: auto_bin_scale_q20 = 22'd1759219;

        // profile=0：有效采样率5 MSPS。
        default: auto_bin_scale_q20 = 22'd3518437;
    endcase
end

wire [53:0] auto_frequency_bin_product;
assign auto_frequency_bin_product =
    measured_frequency * auto_bin_scale_q20;

wire [27:0] auto_frequency_fundamental_bin_q12;
assign auto_frequency_fundamental_bin_q12 =
    (auto_frequency_bin_product + 54'd524288) >> 20;

wire auto_measured_frequency_valid;
assign auto_measured_frequency_valid =
    (measured_frequency >= 32'd10000) &&
    (measured_frequency <= 32'd100000);

// 上电后第一次两秒测频门尚未完成时，临时使用FFT搜索出的整数基波频点。
// 测频结果有效后改用带12位小数的精确频点，避免把整数频点乘到H49时
// 累积很大的中心误差。
wire [27:0] auto_detected_fundamental_bin_q12;
assign auto_detected_fundamental_bin_q12 =
    {4'd0, detected_fundamental_bin, 12'd0};

wire [27:0] auto_fundamental_bin_q12_next;
assign auto_fundamental_bin_q12_next =
    auto_measured_frequency_valid
    ? auto_frequency_fundamental_bin_q12
    : auto_detected_fundamental_bin_q12;

// 频率到频点的乘法结果先寄存，再送入各谐波比较器。
// measured_frequency每两秒才更新一次，多一级寄存不会影响可见刷新速度，
// 却能切断长组合路径，帮助50 MHz时序收敛。
reg [27:0] auto_fundamental_bin_q12 = 28'd0;

always @(posedge clk_50m) begin
    if (!fft_aresetn)
        auto_fundamental_bin_q12 <= 28'd0;
    else
        auto_fundamental_bin_q12 <=
            auto_fundamental_bin_q12_next;
end

wire [27:0] fft_power_index_q12;
assign fft_power_index_q12 =
    {4'd0, fft_power_index, 12'd0};

wire [11:0] thd_auto_max_bin;
assign thd_auto_max_bin =
    (thd_auto_rate_profile == 2'd2)
    ? 12'd410
    : 12'd2048;

wire [AUTO_HIGHEST_HARMONIC:2] thd_auto_harmonic_hits;
genvar auto_harmonic_number;

generate
    for (auto_harmonic_number = 2;
         auto_harmonic_number <= AUTO_HIGHEST_HARMONIC;
         auto_harmonic_number = auto_harmonic_number + 1) begin
        wire [27:0] harmonic_center_q12;

        assign harmonic_center_q12 =
            auto_fundamental_bin_q12 * auto_harmonic_number;

        assign thd_auto_harmonic_hits[auto_harmonic_number] =
            thd_auto_mode &&
            detected_fundamental_valid &&
            (auto_fundamental_bin_q12 != 28'd0) &&
            (fft_power_index <= thd_auto_max_bin) &&
            (fft_power_index_q12 +
             AUTO_HARMONIC_HALF_WIDTH_Q12 >=
             harmonic_center_q12) &&
            (fft_power_index_q12 <=
             harmonic_center_q12 +
             AUTO_HARMONIC_HALF_WIDTH_Q12);
    end
endgenerate

wire thd_auto_harmonic_bin;
assign thd_auto_harmonic_bin = |thd_auto_harmonic_hits; // 命中H2～H49任一窄带即计入谐波

reg [63:0] thd_auto_harmonic_accumulator = 64'd0; // 任务五H2～H49总谐波功率

// 将“当前频点属于哪个频带”的判断结果与该频点功率一起打一拍。
// 否则H2～H49的并行比较和归约或门会直接串在64位累加器之前，
// 组合路径过长，目标Artix-7器件难以满足50 MHz时序。
reg        thd_power_valid_pipeline = 1'b0;
reg        thd_power_last_pipeline  = 1'b0;
reg [11:0] thd_power_index_pipeline = 12'd0;
reg [63:0] thd_bin_power_pipeline   = 64'd0;
reg        thd_in_band_1_pipeline   = 1'b0;
reg        thd_in_band_2_pipeline   = 1'b0;
reg        thd_in_band_3_pipeline   = 1'b0;
reg        thd_in_band_4_pipeline   = 1'b0;
reg        thd_in_band_5_pipeline   = 1'b0;
reg        thd_auto_harmonic_pipeline = 1'b0;

always @(posedge clk_50m) begin
    if (!fft_aresetn) begin
        thd_power_valid_pipeline <= 1'b0;
        thd_power_last_pipeline  <= 1'b0;
        thd_power_index_pipeline <= 12'd0;
        thd_bin_power_pipeline   <= 64'd0;
        thd_in_band_1_pipeline   <= 1'b0;
        thd_in_band_2_pipeline   <= 1'b0;
        thd_in_band_3_pipeline   <= 1'b0;
        thd_in_band_4_pipeline   <= 1'b0;
        thd_in_band_5_pipeline   <= 1'b0;
        thd_auto_harmonic_pipeline <= 1'b0;
    end else begin
        thd_power_valid_pipeline <= fft_power_valid;
        thd_power_last_pipeline  <= fft_power_last;
        thd_power_index_pipeline <= fft_power_index;
        thd_bin_power_pipeline   <= fft_bin_power;
        thd_in_band_1_pipeline   <= thd_in_band_1;
        thd_in_band_2_pipeline   <= thd_in_band_2;
        thd_in_band_3_pipeline   <= thd_in_band_3;
        thd_in_band_4_pipeline   <= thd_in_band_4;
        thd_in_band_5_pipeline   <= thd_in_band_5;
        thd_auto_harmonic_pipeline <= thd_auto_harmonic_bin;
    end
end

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
        thd_auto_harmonic_accumulator <= 64'd0;

        thd_fundamental_power <= 64'd0;
        thd_harmonic_power    <= 64'd0;
        thd_power_ready       <= 1'b0;
    end else begin
        thd_power_ready <= 1'b0;

        if (thd_power_valid_pipeline) begin
            // FFT按自然顺序输出；看到bin 0表示新一帧开始，清零本帧累加器。
            if (thd_power_index_pipeline == 12'd0) begin
                thd_power_1_accumulator <= 64'd0;
                thd_power_2_accumulator <= 64'd0;
                thd_power_3_accumulator <= 64'd0;
                thd_power_4_accumulator <= 64'd0;
                thd_power_5_accumulator <= 64'd0;
                thd_auto_harmonic_accumulator <= 64'd0;
            end else begin
                if (thd_in_band_1_pipeline) begin
                    thd_power_1_accumulator <=
                        thd_power_1_accumulator +
                        thd_bin_power_pipeline;
                end

                if (thd_in_band_2_pipeline) begin
                    thd_power_2_accumulator <=
                        thd_power_2_accumulator +
                        thd_bin_power_pipeline;
                end

                if (thd_in_band_3_pipeline) begin
                    thd_power_3_accumulator <=
                        thd_power_3_accumulator +
                        thd_bin_power_pipeline;
                end

                if (thd_in_band_4_pipeline) begin
                    thd_power_4_accumulator <=
                        thd_power_4_accumulator +
                        thd_bin_power_pipeline;
                end

                if (thd_in_band_5_pipeline) begin
                    thd_power_5_accumulator <=
                        thd_power_5_accumulator +
                        thd_bin_power_pipeline;
                end

                if (thd_auto_harmonic_pipeline) begin
                    thd_auto_harmonic_accumulator <=
                        thd_auto_harmonic_accumulator +
                        thd_bin_power_pipeline;
                end
            end

            // bin 4095不属于任何目标频带，因此TLAST到来时本帧所需累加已经完成。
            // 任务四DAC采样率为10 MHz，第一奈奎斯特区上限为5 MHz；
            // 超过5 MHz的分量会与DAC采样镜像和时钟馈通混叠，
            // 不应继续当作独立谐波加入任务四THD。
            if (thd_power_last_pipeline &&
                thd_frequency_bins_valid) begin
                thd_fundamental_power <=
                    thd_power_1_accumulator;

                case (freq_sel_50m_sync)
                    // 任务四1 kHz、10 kHz、50 kHz：H2～H5都低于5 MHz，全部计入。
                    3'b000,
                    3'b001,
                    3'b010: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator
                            + thd_power_4_accumulator
                            + thd_power_5_accumulator;
                    end

                    // 任务四1 MHz：计入H2、H3、H4；H5正好位于5 MHz边界，不计入。
                    3'b011: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator
                            + thd_power_4_accumulator;
                    end

                    // 任务四1.5 MHz：计入H2=3 MHz与H3=4.5 MHz。
                    3'b100: begin
                        thd_harmonic_power <=
                              thd_power_2_accumulator
                            + thd_power_3_accumulator;
                    end

                    // 任务四2 MHz：5 MHz以下只有H2=4 MHz可独立观测。
                    3'b101: begin
                        thd_harmonic_power <=
                            thd_power_2_accumulator;
                    end

                    // 任务五外接模式：严格THD只使用H2～H49整数次谐波窄带功率和。
                    3'b110: begin
                        thd_harmonic_power <=
                            thd_auto_harmonic_accumulator; // 任务五严格THD分子
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
// 任务四、任务五共用：顺序定点THD计算
// THD = sqrt(谐波总功率/基波功率)。先计算
// ratio_q32=(harmonic_power<<32)/fundamental_power，得到Q32功率比，
// 再开平方得到Q16幅度比。除法与开平方采用逐周期迭代，节省硬件资源。
// thd_millipercent的单位为0.001%，例如2196表示2.196%。
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

reg [31:0] thd_millipercent = 32'd0; // 单位0.001%，如48300表示48.300%
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
// 任务四、任务五共用：稳定数码管THD显示
// 单帧FFT的THD会因噪声和非相干采样轻微波动，因此先对2的整数次幂帧数
// 求平均，再更新数码管。各档平均帧数按有效采样率选择，使显示大约每
// 1.7～2.7秒更新一次，既能稳定读数，也不会长时间没有响应。
// ============================================================
reg [14:0] thd_average_terminal_count;
reg [3:0]  thd_average_shift;

always @(*) begin
    case (freq_sel_50m_sync)
        3'b000: begin
            // 平均64帧，约2.621秒更新一次。
            thd_average_terminal_count = 15'd63;
            thd_average_shift = 4'd6;
        end

        3'b001: begin
            // 平均512帧，约2.097秒更新一次。
            thd_average_terminal_count = 15'd511;
            thd_average_shift = 4'd9;
        end

        3'b010: begin
            // 平均2048帧，约1.678秒更新一次。
            thd_average_terminal_count = 15'd2047;
            thd_average_shift = 4'd11;
        end

        3'b110: begin
            if (thd_auto_rate_profile == 2'd2) begin
                // 50 MSPS下平均32768帧，约2.684秒。
                thd_average_terminal_count = 15'd32767;
                thd_average_shift = 4'd15;
            end else if (thd_auto_rate_profile == 2'd1) begin
                // 10 MSPS下平均4096帧，约1.678秒。
                thd_average_terminal_count = 15'd4095;
                thd_average_shift = 4'd12;
            end else begin
                // 5 MSPS下平均2048帧，约1.678秒。
                thd_average_terminal_count = 15'd2047;
                thd_average_shift = 4'd11;
            end
        end

        3'b011,
        3'b100,
        3'b101: begin
            // 平均32768帧，约2.684秒更新一次。
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

reg [31:0] thd_display_millipercent = 32'd0; // 多帧平均后的稳定显示值
reg        thd_update_toggle = 1'b0;
reg [1:0]  thd_auto_rate_profile_last = 2'd0;

always @(posedge clk_50m) begin
    if (!fft_aresetn) begin
        thd_average_sum   <= 48'd0;
        thd_average_count <= 15'd0;
        thd_display_millipercent <= 32'd0;
        thd_update_toggle <= 1'b0;
        thd_auto_rate_profile_last <= 2'd0;
    end else begin
        thd_auto_rate_profile_last <= thd_auto_rate_profile;

        // 任务五跨越35 kHz或70 kHz分档边界时清空平均器，
        // 防止把不同有效采样率下的FFT结果混在同一次显示平均中。
        if (thd_auto_rate_profile !=
            thd_auto_rate_profile_last) begin
            thd_average_sum   <= 48'd0;
            thd_average_count <= 15'd0;
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
end


wire fft_error_any;

assign fft_error_any =
       fft_event_tlast_unexpected
     | fft_event_tlast_missing
     | fft_event_status_channel_halt
     | fft_event_data_in_channel_halt
     | fft_event_data_out_channel_halt;
    // ============================================================
    // 任务四、任务五ILA调试探针
    // PROBE0：去直流后的11位ADC样本；PROBE1：当前/检测到的基波频点；
    // PROBE2：原始THD，单位0.001%；PROBE3：基波功率低32位；
    // PROBE4：新THD结果脉冲；PROBE5：FFT帧结束；PROBE6：FFT错误汇总。
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


    // 把显示模式开关以及任务三、四、五的测量结果同步到100 MHz显示时钟域。
    // 任务三的measured_frequency产生于50 MHz ADC域，不能直接作为显示控制事件；
    // 因此用frequency_display_value_meta/sync同步稳定的数据总线，
    // 用frequency_display_update_meta/sync/last同步并检测“新结果翻转通知”。
    // display_mode_sync=0显示任务一ID；为1且THD选择为0时显示任务三频率。
    // ============================================================
    reg        display_mode_meta = 1'b0;
    reg        display_mode_sync = 1'b0;
    reg        display_mode_last = 1'b0;

    // 将三位频率选择开关单独同步到100 MHz显示域。
    // freq_sel_display_last用于检测000～111之间的选择码变化，
    // 保证拨到111或离开111时立即重新装载数码管显示数据。
    reg [2:0] freq_sel_display_meta = 3'b000;
    reg [2:0] freq_sel_display_sync = 3'b000;
    reg [2:0] freq_sel_display_last = 3'b000;

    reg thd_display_select_meta = 1'b0;
    reg thd_display_select_sync = 1'b0;
    reg thd_display_select_last = 1'b0;

    reg [31:0] frequency_display_value_meta = 32'd0; // 频率结果跨域第一级寄存
    reg [31:0] frequency_display_value_sync = 32'd0; // 显示域使用的稳定频率值

    reg frequency_display_update_meta = 1'b0; // 更新翻转信号第一级同步
    reg frequency_display_update_sync = 1'b0; // 更新翻转信号第二级同步
    reg frequency_display_update_last = 1'b0; // 保存上一拍，用异或关系检测变化

    reg [31:0] thd_display_value_meta = 32'd0;
    reg [31:0] thd_display_value_sync = 32'd0;

    reg thd_display_update_meta = 1'b0;
    reg thd_display_update_sync = 1'b0;
    reg thd_display_update_last = 1'b0;

    // 只有在“测量显示、频率页面、freq_sel=111”三个条件同时满足时，
    // 才显示任务二DDS理论频率分辨率；学号和THD页面均保持原行为。
    wire dds_resolution_display_active;

    assign dds_resolution_display_active =
        display_mode_sync &&
        !thd_display_select_sync &&
        (freq_sel_display_sync == 3'b111);

    // 频率页面送入Double Dabble的二进制数据源。
    // 普通档位仍使用任务三实测频率；111使用放大10^7后的固定分辨率值。
    wire [31:0] frequency_bcd_source;

    assign frequency_bcd_source =
        (freq_sel_display_sync == 3'b111)
        ? DDS_RESOLUTION_DISPLAY_VALUE
        : frequency_display_value_sync;


    // ============================================================
    // 任务三显示：32位二进制频率转换为八位BCD十进制数字
    //
    // measured_frequency在寄存器中是普通二进制，例如50000并不是
    // “00050000”这八个十进制数字，因此数码管显示前必须做Double Dabble。
    // bcd_shift[63:32]是8个BCD四位组工作区，初始全0；
    // bcd_shift[31:0]保存待转换的32位二进制数。
    // 每一轮先把左侧所有≥5的BCD组分别加3，再把整个64位寄存器左移1位；
    // 重复32轮后，左32位就是八个可显示的十进制数字，耗时320 ns。
    // display_bcd[31:28]为最左一位，display_bcd[3:0]为最右一位。
    // ============================================================
    reg [63:0] bcd_shift     = 64'd0; // 左32位BCD工作区，右32位二进制输入
    reg [5:0]  bcd_iteration = 6'd0;  // 已完成的移位轮数，范围0～31
    reg        bcd_busy      = 1'b0;  // 为1表示转换正在进行
    reg [31:0] display_bcd   = 32'd0; // 转换完成后的8个BCD数字

    reg [63:0] bcd_adjusted;
    integer bcd_digit_index;

    always @(*) begin
        bcd_adjusted = bcd_shift; // 默认保持原值，只修改满足条件的BCD组

        for (bcd_digit_index = 0;
             bcd_digit_index < 8;
             bcd_digit_index = bcd_digit_index + 1) begin

            // 每次只检查并修改一个4位BCD数字，不给整个32位数统一加3。
            if (bcd_shift[ 32 + bcd_digit_index * 4 +: 4] >= 4'd5) begin

                bcd_adjusted[ 32 + bcd_digit_index * 4 +: 4 ]
                 = bcd_shift[ 32 + bcd_digit_index * 4 +: 4 ] + 4'd3;
            end
        end
    end

    wire [63:0] bcd_shift_next;
    // 整体左移时，原二进制区最高位进入BCD工作区最低位，最右端自动补0。
    assign bcd_shift_next = bcd_adjusted << 1;


    always @(posedge clk_in) begin
        // 将两个物理显示选择开关同步到100 MHz显示时钟域。
        // 任务三显示频率时：display_mode=1、thd_display_select=0。
        display_mode_meta <= display_mode;
        display_mode_sync <= display_mode_meta;
        display_mode_last <= display_mode_sync;

        freq_sel_display_meta <= freq_sel;
        freq_sel_display_sync <= freq_sel_display_meta;
        freq_sel_display_last <= freq_sel_display_sync;

        thd_display_select_meta <= thd_display_select;
        thd_display_select_sync <= thd_display_select_meta;
        thd_display_select_last <= thd_display_select_sync;

        // 任务三：同步50 MHz域中长期保持稳定的32位测频结果。
        // measured_frequency每2 s最多变化一次，因此同步完成后有充足稳定时间。
        frequency_display_value_meta <= measured_frequency;
        frequency_display_value_sync <=
            frequency_display_value_meta;

        // 同步“新频率结果”翻转通知。sync与last不相等只持续一个clk_in周期，
        // 该条件相当于100 MHz显示域中的新结果有效脉冲。
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

        // 任一显示选择开关改变时，立即按新模式重新装载当前数据并启动BCD转换。
        if ((display_mode_sync != display_mode_last) ||
            (thd_display_select_sync !=
             thd_display_select_last) ||
            (freq_sel_display_sync !=
             freq_sel_display_last)) begin

            bcd_shift <= {
                32'd0, // 左32位BCD工作区先清零
                thd_display_select_sync
                ? thd_display_value_sync
                : frequency_bcd_source
            };

            bcd_iteration <= 6'd0;
            bcd_busy      <= 1'b1;

        end else if (display_mode_sync &&
                     !thd_display_select_sync &&
                     (frequency_display_update_sync !=
                      frequency_display_update_last)) begin

            // 任务三频率显示模式收到新结果：把二进制Hz值装入右32位。
            bcd_shift <= {
                32'd0,
                frequency_bcd_source
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
            // 每个100 MHz时钟完成一轮“BCD组加3并整体左移”。
            bcd_shift <= bcd_shift_next;

            if (bcd_iteration == 6'd31) begin
                // 第32轮必须保存组合逻辑产生的next值，才能包含最后一次移位。
                display_bcd <= bcd_shift_next[63:32];
                bcd_busy    <= 1'b0;
            end else begin
                bcd_iteration <= bcd_iteration + 6'd1;
            end
        end
    end


    // ============================================================
    // 任务一核心：八位七段数码管动态扫描
    //
    // 开发板丝印开关4（display_mode）= 0：
    //     显示固定学生ID 20051121，这是任务一工作模式。
    //
    // 开关4 = 1、开关3 = 0：
    //     freq_sel=000～110时显示任务三测得的频率，单位Hz；
    //     freq_sel=111时显示任务二DDS理论分辨率0.0023283 Hz。
    //
    // 开关4 = 1、开关3 = 1：
    //     显示后续任务测得的THD，并保留三位小数。
    //
    // 动态扫描原理：任意时刻只选通一位数码管，
    // 快速循环扫描0～7号位置，利用视觉暂留形成八位同时显示的效果。
    // ============================================================
    // 扫描时钟计数器：决定当前数码管位置保持多长时间。
    reg [31:0] scan_count = 32'd0;

    // 当前扫描位置，三位宽度可自然循环表示0～7。
    reg [2:0]  scan_index = 3'd0;

    // THD页面在第4位后显示小数点，形成xxx.xxxx形式；
    // DDS分辨率页面在最左位后显示小数点，形成0.0023283 Hz。
    wire measurement_decimal_point_active;

    assign measurement_decimal_point_active =
        (display_mode_sync &&
         thd_display_select_sync &&
         (scan_index == 3'd4)) ||
        (dds_resolution_display_active &&
         (scan_index == 3'd0));

    // 当前扫描位置准备显示的十进制数字0～9。
    reg [3:0] digit;

    // 当前数字对应的八位段码，位序为{dp,g,f,e,d,c,b,a}。
    reg [7:0] segment_code;

    // 每个100 MHz时钟上升沿执行一次扫描计数。
    always @(posedge clk_in) begin
        if (scan_count == SCAN_CYCLES - 1) begin
            // 已经过SCAN_CYCLES个时钟：计数器清零，切换到下一位。
            scan_count <= 32'd0;

            // 三位寄存器从7再加1时自动回到0，实现0～7循环扫描。
            scan_index <= scan_index + 3'd1;
        end else begin
            // 尚未达到换位条件，继续保持当前位置并累加计数。
            scan_count <= scan_count + 32'd1;
        end
    end


    // 根据当前扫描位置选择这一位应该显示的数字。
    // always @(*)表示组合逻辑：scan_index或显示数据变化时立即重新计算。
    always @(*) begin
        if (!display_mode_sync) begin
            // 任务一ID显示模式：位置0～7依次显示2、0、0、5、1、1、2、1。
            case (scan_index)
                3'd0: digit = 4'd2; // 第0号位置显示2（ID第1位）
                3'd1: digit = 4'd0; // 第1号位置显示0（ID第2位）
                3'd2: digit = 4'd0; // 第2号位置显示0（ID第3位）
                3'd3: digit = 4'd5; // 第3号位置显示5（ID第4位）
                3'd4: digit = 4'd1; // 第4号位置显示1（ID第5位）
                3'd5: digit = 4'd1; // 第5号位置显示1（ID第6位）
                3'd6: digit = 4'd2; // 第6号位置显示2（ID第7位）
                3'd7: digit = 4'd1; // 第7号位置显示1（ID第8位）
                default: digit = 4'd0;
            endcase
        end else begin
            // 测量结果显示模式：从BCD结果中选择当前扫描位置的十进制数字。
            // 任务三频率已经按Hz转换成八位BCD，因此不需要额外小数点。
            case (scan_index)
                3'd0: digit = display_bcd[31:28]; // 最左侧千万位
                3'd1: digit = display_bcd[27:24]; // 百万位
                3'd2: digit = display_bcd[23:20]; // 十万位
                3'd3: digit = display_bcd[19:16]; // 万位
                3'd4: digit = display_bcd[15:12]; // 千位
                3'd5: digit = display_bcd[11:8];  // 百位
                3'd6: digit = display_bcd[7:4];   // 十位
                3'd7: digit = display_bcd[3:0];   // 最右侧个位
                default: digit = 4'd0;
            endcase
        end
    end


    // ============================================================
    // 数字到七段段码的组合译码
    // 段码为高电平有效，位序为{dp, g, f, e, d, c, b, a}。
    // 例如数字2点亮a、b、d、e、g，对应8'b0101_1011 = 8'h5B。
    // ============================================================
    always @(*) begin
        case (digit)
            4'd0: segment_code = 8'h3F; // 数字0：点亮a、b、c、d、e、f
            4'd1: segment_code = 8'h06; // 数字1：点亮b、c
            4'd2: segment_code = 8'h5B; // 数字2：点亮a、b、d、e、g
            4'd3: segment_code = 8'h4F; // 数字3：点亮a、b、c、d、g
            4'd4: segment_code = 8'h66; // 数字4：点亮b、c、f、g
            4'd5: segment_code = 8'h6D; // 数字5：点亮a、c、d、f、g
            4'd6: segment_code = 8'h7D; // 数字6：点亮a、c、d、e、f、g
            4'd7: segment_code = 8'h07; // 数字7：点亮a、b、c
            4'd8: segment_code = 8'h7F; // 数字8：点亮a～g全部七段
            4'd9: segment_code = 8'h6F; // 数字9：点亮a、b、c、d、f、g
            default: segment_code = 8'h00; // 非法数字时全部熄灭
        endcase
    end


    // 仿真和FPGA配置完成后的初始输出：所有位选和段线全部关闭。
    initial begin
        seg_cs_pin     = 8'h00;
        seg_data_0_pin = 8'h00;
        seg_data_1_pin = 8'h00;
    end


    // ============================================================
    // 位选、段数据分组与换位消隐
    //
    // 在每个新显示位置开始时，先关闭全部位选，再更新段数据；
    // 下一拍才打开新位置，可避免旧位选与新段码短暂重叠造成重影。
    // 非阻塞赋值判断使用时钟沿到来前的旧scan_count值。
    // ============================================================
    always @(posedge clk_in) begin
        if (scan_count == 0) begin
            // 消隐阶段：暂时关闭八位数码管。
            seg_cs_pin <= 8'h00;

            if (scan_index < 4) begin
                // 第0～3号位置使用第0组段数据线。
                // 任务一中display_mode_sync=0，三目运算结果就是segment_code。
                seg_data_0_pin <=
                    measurement_decimal_point_active
                    ? (segment_code | 8'h80)
                    : segment_code;

                // 未使用的另一组段数据清零，避免误点亮。
                seg_data_1_pin <= 8'h00;
            end else begin
                // 第4～7号位置使用第1组段数据线。
                seg_data_0_pin <= 8'h00;
                seg_data_1_pin <=
                    measurement_decimal_point_active
                    ? (segment_code | 8'h80)
                    : segment_code;
            end
        end else begin
            // 正常显示阶段：把最低位的1左移scan_index位，形成独热位选。
            // scan_index为0～7时，结果依次为01、02、04、08、10、20、40、80。
            seg_cs_pin <=
                8'b0000_0001 << scan_index;
        end
    end

endmodule
