# 数字系统设计实验——任务一：八位数码管显示ID

> 学号：20051121  
> 姓名：待填写  
> 班级：待填写  
> 开发板：EGo1（Xilinx Artix-7，器件 `xc7a35tcsg324-1`）  
> 开发工具：Vivado 2019.1  
> 工程状态：代码已完成，已通过仿真并完成上板验证

## 1. 任务目标

使用FPGA驱动开发板上的八位七段数码管，通过动态扫描方式显示学生ID `20051121`。设计需要完成扫描节拍产生、八位数字选择、数字到七段段码的译码、位选输出、两组段数据输出和换位消隐，并通过行为仿真和上板实验验证显示结果。

本任务是后续测频和THD结果显示的基础。后续任务继续复用数码管扫描、段码译码和位选输出，只改变八个显示位置的数据来源。

## 2. 系统输入输出与总体结构

任务一使用100 MHz板载时钟 `clk_in`，输出八位位选信号和两组八位段数据：

| 信号 | 方向 | 位宽 | 作用 |
|---|---:|---:|---|
| `clk_in` | 输入 | 1 | 100 MHz板载系统时钟 |
| `seg_cs_pin` | 输出 | 8 | 八位数码管的独热位选信号 |
| `seg_data_0_pin` | 输出 | 8 | 第0～3位数码管共用的段数据 |
| `seg_data_1_pin` | 输出 | 8 | 第4～7位数码管共用的段数据 |

任务一的数据通路为：

```text
100 MHz时钟
    ↓
scan_count扫描计数器
    ↓ 每50 000个时钟切换一次
scan_index（0～7）
    ├→ 选择当前位置的ID数字
    ├→ segment_code数字到段码译码
    ├→ 选择seg_data_0_pin或seg_data_1_pin
    └→ seg_cs_pin独热位选
             ↓
      八位数码管动态显示20051121
```

八位数码管并非同时由八套独立段线驱动。设计在任意时刻只选通其中一位，并快速循环扫描八位。由于视觉暂留，人眼看到的是稳定的八位数字。

## 3. 动态扫描参数设计

最终工程中扫描参数为：

```verilog
parameter integer SCAN_CYCLES = 50_000;
```

板载时钟频率为：

\[
f_{clk}=100\ \text{MHz}
\]

单个时钟周期为：

\[
T_{clk}=\frac{1}{100\ \text{MHz}}=10\ \text{ns}
\]

每个显示位置保持的时间为：

\[
T_{digit}=50\,000\times10\ \text{ns}=0.5\ \text{ms}
\]

八位完成一轮扫描所需时间为：

\[
T_{frame}=8\times0.5\ \text{ms}=4\ \text{ms}
\]

理论整屏刷新频率为：

\[
f_{frame}=\frac{1}{4\ \text{ms}}=250\ \text{Hz}
\]

250 Hz高于人眼能够明显察觉的闪烁频率，因此能够形成连续稳定的显示。该数值是根据时钟和参数计算得到的理论值，本实验尚未使用示波器单独测量位选刷新频率。

## 4. 关键Verilog实现分析

最终集成工程顶层文件为：

```text
D:\Xilinx\code\project_1\project_1.srcs\sources_1\new\id_display.v
```

当前顶层还包含后续DDS、ADC、测频和THD功能。本节只分析其中由任务一建立并在最终工程中继续使用的数码管显示部分。当 `display_mode_sync=0` 时，显示逻辑进入ID显示模式。

### 4.1 扫描计数与位置切换

```verilog
reg [31:0] scan_count = 32'd0;
reg [2:0]  scan_index = 3'd0;

always @(posedge clk_in) begin
    if (scan_count == SCAN_CYCLES - 1) begin
        scan_count <= 32'd0;
        scan_index <= scan_index + 3'd1;
    end else begin
        scan_count <= scan_count + 32'd1;
    end
end
```

`scan_count`在每个100 MHz时钟上升沿加1。计数达到 `SCAN_CYCLES-1` 后清零，同时令三位寄存器 `scan_index` 加1。三位二进制数自然在0～7之间循环，因此不需要额外编写从7返回0的判断。

时序逻辑使用非阻塞赋值 `<=`。同一时钟沿内的判断读取寄存器的旧值，所有寄存器的新值在该时钟沿后统一更新。

### 4.2 选择八个位置对应的ID数字

```verilog
always @(*) begin
    if (!display_mode_sync) begin
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
        // 后续任务的测量结果显示分支
    end
end
```

`scan_index`表示当前扫描位置，`digit`表示该位置应该显示的十进制数字。位置0～7依次映射为 `2、0、0、5、1、1、2、1`。

### 4.3 数字到七段段码的译码

```verilog
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
```

段码位序为 `{dp,g,f,e,d,c,b,a}`，并采用高电平点亮。例如数字2需要点亮 `a、b、d、e、g`，对应二进制 `0101_1011`，即 `8'h5B`。这里的 `8'h` 表示“8位十六进制常量”。

`segment_code`虽然声明为 `reg`，但它由 `always @(*)`组合逻辑产生，并不表示一定综合成物理寄存器。

### 4.4 段数据分组、位选与换位消隐

最终集成代码还包含后续THD显示使用的小数点控制。由于任务一中 `display_mode_sync=0`，该条件恒为假，因此任务一工作状态下的等效逻辑如下：

```verilog
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
        seg_cs_pin <= 8'b0000_0001 << scan_index;
    end
end
```

前四位和后四位分别使用 `seg_data_0_pin`、`seg_data_1_pin`。位选表达式把最低位的1向左移动 `scan_index` 位，从而形成独热码：

```text
scan_index： 0   1   2   3   4   5   6   7
seg_cs_pin：01  02  04  08  10  20  40  80
```

切换位置时，设计先令 `seg_cs_pin=0`关闭全部数码管，再更新段数据，之后才使能下一位。这样可以避免旧位选与新段码短暂重叠而产生重影。

## 5. Testbench与仿真设计

仿真文件为：

```text
D:\Xilinx\code\project_1\project_1.srcs\sim_1\new\tb_id_display.v
```

实际Testbench如下：

```verilog
`timescale 1ns / 1ps

module tb_id_display;

    reg clk_in = 1'b0;
    reg [2:0] freq_sel = 3'b000;
    reg       display_mode = 1'b0;
    reg       thd_display_select = 1'b0;
    reg [9:0] ad_in = 10'd0;

    wire [7:0] seg_cs_pin;
    wire [7:0] seg_data_0_pin;
    wire [7:0] seg_data_1_pin;

    // 每5 ns翻转一次，周期为10 ns，即100 MHz。
    always #5 clk_in = ~clk_in;

    // 仿真时把每位扫描周期缩短为10个时钟，减少等待时间。
    id_display #(
        .SCAN_CYCLES(10)
    ) dut (
        .clk_in             (clk_in),
        .freq_sel           (freq_sel),
        .display_mode       (display_mode),
        .thd_display_select (thd_display_select),
        .ad_in              (ad_in),
        .seg_cs_pin         (seg_cs_pin),
        .seg_data_0_pin     (seg_data_0_pin),
        .seg_data_1_pin     (seg_data_1_pin)
    );

    initial begin
        #2000;
        $finish;
    end

endmodule
```

`display_mode=0`固定选择ID显示。硬件默认每位扫描50 000个时钟；Testbench使用参数覆盖 `.SCAN_CYCLES(10)`，使每位只保持100 ns，一轮扫描为800 ns。2 μs仿真能够观察约2.5轮扫描，但不改变扫描逻辑本身。

### 5.1 动态扫描仿真结果

![动态扫描仿真概览](../../assets/task1/task1_sim_dynamic_scan_overview.png)

仿真中 `seg_cs_pin`按照 `01→02→04→08→10→20→40→80`循环。相应的数字和段码为：

| `scan_index` | `digit` | `segment_code` | 显示数字 |
|---:|---:|---:|---:|
| 0 | 2 | `5B` | 2 |
| 1 | 0 | `3F` | 0 |
| 2 | 0 | `3F` | 0 |
| 3 | 5 | `6D` | 5 |
| 4 | 1 | `06` | 1 |
| 5 | 1 | `06` | 1 |
| 6 | 2 | `5B` | 2 |
| 7 | 1 | `06` | 1 |

仿真结果与ID `20051121`一致。相邻两位数字相同时，段数据总线在波形上可能保持不变，但位选信号仍然切换，因此两个不同位置会分别显示相同数字。

### 5.2 换位消隐仿真结果

![换位消隐局部波形](../../assets/task1/task1_sim_blanking_detail.png)

局部波形显示位选信号出现 `02→00→04`，证明从一位切换到下一位时存在一个时钟周期的全灭阶段。波形中看到 `scan_count=1`而位选仍为0，是因为该时钟沿的条件判断使用旧值 `scan_count=0`，随后非阻塞赋值才把计数器更新为1。

## 6. 引脚与时钟约束

约束文件为：

```text
D:\Xilinx\code\project_1\project_1.srcs\constrs_1\new\id_display.xdc
```

系统时钟约束为：

```tcl
set_property -dict {PACKAGE_PIN P17 IOSTANDARD LVCMOS33} [get_ports clk_in]
create_clock -name sys_clk -period 10.000 [get_ports clk_in]
```

其中 `PACKAGE_PIN P17`指定物理管脚，`LVCMOS33`指定3.3 V CMOS电平标准，`create_clock`告诉时序分析工具输入时钟周期为10 ns。它只描述外部已有时钟，不会在FPGA内部产生时钟。

![数码管引脚约束](../../assets/task1/task1_xdc_seven_segment_pins.png)

数码管相关约束共24根：8根位选、8根第一组段线和8根第二组段线。段线位序均为 `a、b、c、d、e、f、g、dp`，与Verilog中的 `{dp,g,f,e,d,c,b,a}`表示方式一致。

## 7. 综合、实现与比特流生成

综合将Verilog转换为寄存器、加法器、比较器、查找表和选择器构成的网表；实现阶段完成FPGA内部布局布线并检查实际路径延迟；随后生成用于配置FPGA的 `.bit`比特流文件。

![实现完成与时序结果](../../assets/task1/task1_implementation_timing.png)

任务一实现截图中可见：

- WNS为5.376 ns；
- TNS为0.000 ns；
- Setup失败端点数为0；
- 界面显示所有用户时序约束均已满足。

因此该版本在所设置的100 MHz时钟约束下通过实现时序检查。

![比特流生成完成](../../assets/task1/task1_bitstream_completed.png)

比特流生成成功后，通过Hardware Manager和JTAG下载至FPGA。

![Hardware Manager下载成功](../../assets/task1/task1_hardware_manager_programmed.png)

Hardware Manager中器件 `xc7a35t_0`显示为 `Programmed`，说明比特流已经成功写入FPGA配置存储单元。

## 8. 上板实验结果与分析

### 8.1 测试条件

- 开发板正常供电；
- 通过板载USB/JTAG接口下载比特流；
- 输入时钟为100 MHz；
- 使用硬件默认参数 `SCAN_CYCLES=50_000`；
- 显示内容为学生ID `20051121`。

### 8.2 实验结果

![任务一上板实拍](../../assets/task1/task1_hardware_id_display.jpg)

实拍照片中八位数码管显示 `20051121`，与设计目标一致。该结果共同验证了扫描计数、数字选择、段码译码、位选输出、段数据输出、XDC管脚映射和JTAG下载链路。

由于照片曝光时间覆盖了多次动态扫描，画面呈现八位同时点亮的效果，实际硬件仍是逐位快速扫描。若手机拍摄时出现缺位或亮度不一致，可使用更长曝光、调整防闪烁设置或补充短视频记录。

### 8.3 理论值、仿真值和实测结果的区分

| 项目 | 类型 | 结果 |
|---|---|---|
| 单个系统时钟周期 | 理论计算 | 10 ns |
| 单位扫描时间 | 理论计算 | 0.5 ms |
| 整屏刷新频率 | 理论计算 | 250 Hz |
| Testbench整屏扫描周期 | 仿真设置与波形 | 800 ns |
| 独热位选顺序 | 仿真结果 | `01→02→04→08→10→20→40→80` |
| 换位消隐 | 仿真结果 | 位选经过 `00` |
| 数码管显示内容 | 上板实测 | `20051121` |

## 9. 实验中遇到的问题及解决方法

### 9.1 最终集成顶层增加端口后，原Testbench端口不完整

后续任务在顶层增加了 `freq_sel`、`display_mode`、`thd_display_select`和`ad_in`等输入。重新验证任务一时，原Testbench需要为这些端口提供确定值。解决方法是在Testbench中将 `display_mode`固定为0，并把与任务一无关的其他输入固定为0，使最终集成工程进入ID显示模式。

### 9.2 硬件扫描参数导致仿真等待时间过长

硬件使用 `SCAN_CYCLES=50_000`，一轮扫描需要4 ms；若直接用于行为仿真，观察八位变化需要等待大量时钟周期。解决方法是在实例化时使用 `.SCAN_CYCLES(10)`覆盖参数，只缩短仿真扫描时间，不改变状态转移和译码逻辑。

### 9.3 仿真文件曾被另一个仿真进程占用

启动仿真时曾出现 `simulate.log`正被另一进程使用的提示。关闭原有仿真会话并重新启动行为仿真后，波形能够正常生成。该问题属于仿真工具会话冲突，不是Verilog逻辑错误。

## 10. AI使用记录与错误更正

### 10.1 AI参与内容

- 协助梳理动态扫描、段码译码、独热位选和换位消隐原理；
- 结合真实模块名和信号名解释非阻塞赋值时序；
- 指导补全最终集成顶层对应的Testbench输入；
- 协助核对仿真波形并整理实验截图；
- 协助区分理论计算、仿真结果和上板实测证据；
- 协助形成任务一报告初稿。

### 10.2 错误与更正记录

1. **任务范围识别错误**  
   AI曾根据工作区中的任务二备份，错误地把当前复盘范围识别为多频率正弦输出。用户指出当前内容实际是任务一ID显示和之后的单频率正弦初步实验。更正后，报告先独立整理任务一，并以最终工程中的ID显示分支为依据。

2. **示例代码与源代码区分不清**  
   AI在解释左移时写出 `8'b0000_0001 << 5`作为数值代入示例，但未立即强调它不是源文件中的原句，导致用户在代码中无法找到。实际源代码为 `8'b0000_0001 << scan_index`；当 `scan_index=5`时，才可代入得到 `8'b0010_0000`。此后讲解明确区分“真实代码”和“代入推演”。

上述更正已经通过最终源文件和实际仿真波形核对。

## 11. 结论

本任务使用100 MHz系统时钟和可参数化计数器产生动态扫描节拍，通过三位扫描索引循环选择八个显示位置，再由组合译码逻辑生成数字0～9的七段段码。两组段数据总线分别服务前四位和后四位，独热位选信号确定当前点亮位置，换位消隐逻辑降低了重影风险。

行为仿真验证了ID数字顺序、段码、独热位选和消隐过程；实现结果满足100 MHz时序约束；比特流通过JTAG成功下载；上板照片显示 `20051121`。因此任务一设计达到预期目标，并为后续测频和THD结果的数码管显示提供了可复用的显示模块。

## 12. 当前材料状态

| 材料 | 状态 |
|---|---|
| 最终工程中任务一相关Verilog | 已核对 |
| Testbench | 已核对并完成仿真 |
| 动态扫描总览波形 | 已归档 |
| 换位消隐局部波形 | 已归档 |
| XDC数码管引脚截图 | 已归档 |
| 任务一实现及时序截图 | 已归档 |
| 比特流生成成功截图 | 已归档 |
| Hardware Manager下载截图 | 已归档 |
| 数码管上板照片 | 已归档 |
| 位选信号刷新频率示波器实测 | 未进行，报告中按理论值表述 |


