# 服务启动记录模板

复制本模板为本轮服务启动记录文件后填写。每次启动或重启服务都保留一份独立记录。

## 基本信息

- 轮次：
- 启动时间：
- 执行人或执行代理：
- vllm-ascend 仓库路径：
- 当前分支：
- 当前 commit：
- 模型路径：
- 服务名：
- 服务地址：
- 端口：
- 日志路径：

## 启动前检查

- `pip show vllm` 结果：
- `pip show vllm-ascend` 结果：
- 模型路径检查：
- 网卡检查：
- 端口占用检查：
- 工作区是否存在用户改动：
- 本轮是否需要停止旧服务：是 / 否
- 停止旧服务的命令与结果：

## 启动配置

- 启动脚本路径：`/workspace/sh/vllm.sh`
- 启动脚本是否由用户确认：是 / 否
- 本轮相对上轮的启动脚本变化：
- 关键环境变量：
  - HCCL_DETERMINISTIC：
  - HCCL_IF_IP：
  - GLOO_SOCKET_IFNAME：
  - TP_SOCKET_IFNAME：
  - HCCL_SOCKET_IFNAME：
  - VLLM_ASCEND_APPLY_DSV4_PATCH：
  - VLLM_VERSION：
- 关键启动参数：
  - served-model-name：
  - data-parallel-size：
  - data-parallel-size-local：
  - tensor-parallel-size：
  - enable-expert-parallel：
  - quantization：
  - tokenizer-mode：
  - reasoning-parser：
  - additional-config：

## 启动命令

```bash

```

## 成功判定

- 日志关键字检查：
  - `Route: /v1/chat/completions`：
  - `Route: /v1/completions`：
  - `Started server process`：
  - `Application startup complete`：
- 健康检查命令：

```bash
curl -sS -w '\nHTTP_STATUS=%{http_code}\n' http://127.0.0.1:7000/v1/models
```

- 健康检查响应摘要：
- HTTP 状态：
- 是否包含模型列表或 `ds`：
- 启动结果：成功 / 失败
- 采用的成功判定依据：

## 失败排查

- 失败关键日志：
- Ascend/NPU plog 关键片段：
- 端口占用结果：
- 模型路径检查结果：
- 网卡检查结果：
- 常见失败关键字命中：
- 下一步处理：

## 本轮结论

- 是否可以进入 badcase 复现：是 / 否
- 不能进入复现的原因：
- 下一轮启动需要调整的内容：
