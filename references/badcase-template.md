# Badcase 记录模板

复制本模板为本轮 badcase 记录文件后填写。每轮复现必须能按这里记录的信息原样重放。

## 基本信息

- Badcase 名称：
- 记录时间：
- 执行人或执行代理：
- vllm-ascend 仓库路径：
- 当前分支：
- 当前 commit：
- 本轮代码 diff 摘要：
- 模型路径：
- 服务地址：
- 服务日志路径：
- Ascend/NPU plog 路径：

## 请求信息

- 请求接口：`/v1/chat/completions` / `/v1/completions` / 其他：
- 请求命令：

```bash

```

- 请求 payload：

```json
{}
```

- 固定参数：
  - model：
  - temperature：
  - top_p：
  - top_k：
  - max_tokens：
  - seed：
  - stream：
  - dtype：
  - 其他会影响输出的参数：

## 期望现象与 golden

- 异常类型：输出不一致 / logits 偏差 / token 序列异常 / NaN / Inf / 崩溃 / 其他：
- 期望输出或正确行为：
- 实际异常输出：
- 首个异常 token 或 step：
- golden 是否存在：是 / 否
- golden 来源：CPU / GPU / 原生 vLLM / 历史正确提交 / 用户提供 / 其他：
- golden 分支或 commit：
- golden 运行环境：
- golden 请求 payload 是否与当前 badcase 一致：是 / 否 / 差异如下：
- 无 golden 时的自洽定位依据：

## 复现结果

| 轮次 | 服务日志 | HTTP 状态 | 响应摘要 | token 序列是否稳定 | topk 是否稳定 | 备注 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 |  |  |  |  |  |  |
| 2 |  |  |  |  |  |  |
| 3 |  |  |  |  |  |  |

## 证据记录

- 完整响应保存位置：
- 请求侧日志位置：
- 服务端日志关键片段：
- dump 根目录：
- dump metadata 文件：
- 生成 token 序列：
- 每步 topk token id 和 logits/logprobs：
- hidden_states 或中间 tensor dump：
- 首个分歧点：

## 本轮判断

- 复现是否成立：是 / 否
- 当前最小可疑范围：
- 支持该判断的证据：
- 下一轮验证点：
