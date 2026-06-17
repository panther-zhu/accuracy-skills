# 问题复现指导

本文件用于沉淀 vllm-ascend 精度问题复现前置条件和 badcase 复现方法。它与服务启动指导隔离；服务启动方式仍以 [service-startup-guide.md](service-startup-guide.md) 为准，本文件只描述复现问题前需要额外开启的确定性配置和 badcase 要求。

## 1. 复现前置条件

复现前必须同时完成两个条件：

- 开启确定性计算。
- 准备好可重复执行的 badcase。

两个条件未完成时，不要进入请求复现和精度判断。

## 2. 开启确定性计算

确定性计算包含两步：修改实际启动脚本、修改 vllm-ascend 代码。

### 2.1 修改实际启动脚本

只修改实际运行的启动脚本 `/workspace/sh/vllm.sh`，不要直接修改服务启动参考文档。

确认 `/workspace/sh/vllm.sh` 中包含：

```bash
export HCCL_DETERMINISTIC=true
```

若存在注释行：

```bash
#export HCCL_DETERMINISTIC=true
```

将其取消注释。修改后必须重新拉起服务，确保环境变量生效。

### 2.2 修改 vllm-ascend 代码

在用户提供的 vllm-ascend 仓库中定位文件：

```text
vllm_ascend/worker/model_runner_v1.py
```

在 `NPUModelRunner` 类的 `__init__` 方法中添加：

```python
torch.use_deterministic_algorithms(True)
```

添加要求：

- 确认文件中已导入 `torch`；如果没有导入，先补充 `import torch`。
- 将调用放在 `NPUModelRunner.__init__` 的初始化早期位置，确保模型执行前生效。
- 避免重复添加同一行。
- 修改后必须重新拉起服务，确保新代码被加载。
- 如果开启确定性后出现非确定性算子报错，记录完整错误栈和算子名称，再进入代码定位阶段。

## 3. 准备 badcase

badcase 必须能被后续轮次原样重放。若用户没有提供 badcase，先要求用户补充，或从当前问题描述中整理一个可复用 badcase。

badcase 至少包含：

- 请求接口：例如 `/v1/chat/completions` 或 `/v1/completions`。
- 请求 payload：包括 `model`、prompt/messages、`temperature`、`top_p`、`max_tokens`、seed、stream 等参数。
- 期望现象：错误输出、首个异常 token、logits 偏差、崩溃栈或与参考输出的不一致点。
- 参考结果或无 golden 说明：若有 CPU、GPU、原生 vLLM、历史正确版本或用户提供的正确输出，记录为参考结果；若没有 golden，记录无 golden 状态和计划采用的自洽定位依据。
- 复现命令或脚本：确保后续每一轮可以原样重放。
- 本轮服务日志路径：例如 `/workspace/log/log-N.log`。

badcase 记录格式优先复制并填写：[badcase-template.md](badcase-template.md)。

整理 badcase 时固定所有会影响输出的参数。采样类请求优先设置确定性参数，例如固定 seed、使用低温或贪心解码；若问题只在采样下出现，保留原采样参数并明确记录。

## 4. 发送请求复现

使用固定 badcase 请求复现精度问题。请求必须尽量稳定：

- 固定模型名、prompt/messages、采样参数、seed、temperature、top_p、max_tokens、dtype 等参数。
- 对比任务使用相同输入、相同服务端配置、相同客户端请求。
- 若用户提供参考输出，保留参考输出并逐项比较。

发送请求后收集以下证据：

- 请求命令或请求脚本。
- 请求 payload。
- 响应正文、状态码和耗时。
- 服务端日志中与本次请求对应的片段。
- 错误栈、warning、算子 fallback、dtype cast、shape、device、rank、graph compile、kernel launch 等异常线索。

## 5. 判断复现是否成立

判断精度问题时优先使用可量化标准：

- 生成 token 序列是否一致。
- logits、hidden states 或中间张量误差是否超过阈值。
- 首个分歧 token 的位置。
- 特定算子输入输出是否出现 NaN、Inf、溢出、截断或 dtype 非预期转换。
- 与 CPU、GPU、原生 vLLM 或历史正确提交的差异。

若 badcase 无法复现，先确认确定性计算是否已生效、服务是否加载了修改后的代码、请求参数是否与 badcase 完全一致，再判断是否需要重新准备 badcase。
