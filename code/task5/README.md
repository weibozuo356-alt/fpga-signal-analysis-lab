# 任务五代码与验证说明

任务五H2～H49严格THD逻辑已经集成在[最终顶层RTL](../final/id_display.v)中。

本目录的[test_task5_thd_regression.py](test_task5_thd_regression.py)用于：

- 计算方波20%～80%占空比和标准三角波的理论THD；
- 验证H2～H49截断误差小于3%；
- 检查三档平均抽取在边界附近的理论幅频影响；
- 静态确认最终RTL使用整数次谐波窄带和，而非宽带THD+N。

运行：

```text
python code/task5/test_task5_thd_regression.py code/final/id_display.v
```

该脚本是理论与源码回归，不是完整的Xilinx FFT IP端到端Verilog Testbench。
