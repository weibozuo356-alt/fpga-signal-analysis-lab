# 任务四代码与验证说明

任务四已经集成在[最终顶层RTL](../final/id_display.v)中，没有另存一份容易与最终版本分叉的顶层副本。

本目录提供固定档位配置回归脚本：[test_task4_configuration.py](test_task4_configuration.py)。它检查六档抽取倍数、有效采样率、FFT基波频点、4096点Hann系数文件和任务四频带逻辑。

运行：

```text
python code/task4/test_task4_configuration.py \
  code/final/id_display.v code/final/hann_4096_q15.mem
```

该脚本不是包含Xilinx FFT IP的端到端Verilog Testbench。任务四完整RTL仿真仍待补建，当前上板证据见[任务四实验材料](../../assets/task4/)。
