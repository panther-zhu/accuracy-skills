# 服务启动指导

本文件用于沉淀 vllm-ascend 精度问题排查中的服务启动信息。执行服务启动前先读取本文件；每次启动方式变化后同步更新本文件。

## 1. 服务启动依据

- 服务启动依赖：服务依赖 `vllm` 与 `vllm-ascend`，优先检查两者是否存在；不存在则停止启动并报错。
- 查看方法：
```bash
pip show vllm
pip show vllm-ascend
```


## 2. 服务启动脚本

- 服务启动脚本参考模板：
```bash
unset ftp_proxy
unset https_proxy
unset http_proxy
rm -rf ~/ascend/log

nic_name="enp162s0f0"
if ! ip link show "$nic_name" >/dev/null 2>&1; then
  echo "网卡 $nic_name 不存在，请先通过 ip addr 确认可用网卡"
  exit 1
fi

local_ip=`ifconfig $nic_name | grep 'inet ' | awk '{print $2}'`
echo $local_ip

#export HCCL_DETERMINISTIC=true

export HCCL_OP_EXPANSION_MODE="AIV"
export HCCL_IF_IP=$local_ip
export GLOO_SOCKET_IFNAME=$nic_name
export TP_SOCKET_IFNAME=$nic_name
export HCCL_SOCKET_IFNAME=$nic_name

export VLLM_ASCEND_APPLY_DSV4_PATCH=1
export VLLM_VERSION=0.20.2
export HCCL_BUFFSIZE=2048

export VLLM_RPC_TIMEOUT=360000
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS=3000
export HCCL_EXEC_TIMEOUT=200
export HCCL_CONNECT_TIMEOUT=120

export OMP_PROC_BIND=false
export OMP_NUM_THREADS=10
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ACL_OP_INIT_MODE=1

#export VLLM_ASCEND_ENABLE_FLASHCOMM1=1
#export USE_MULTI_GROUPS_KV_CACHE=1
#export USE_MULTI_BLOCK_POOL=1
#export VLLM_ASCEND_ENABLE_FUSED_MC2=0

exec vllm serve /mnt/weight/DeepSeek-V4-Flash-w8a8-mtp \
  --safetensors-load-strategy 'prefetch' \
  --max_model_len 135000  \
  --max-num-batched-tokens 2048 \
  --served-model-name ds \
  --gpu-memory-utilization 0.9 \
  --max-num-seqs 64 \
  --data-parallel-size 2 \
  --data-parallel-size-local 2 \
  --data-parallel-start-rank 0 \
  --tensor-parallel-size 8 \
  --enable-expert-parallel \
  --quantization ascend \
  --port 7000 \
  --host 0.0.0.0 \
  --block-size 128 \
  --async-scheduling \
  --compilation-config '{"cudagraph_mode": "FULL_DECODE_ONLY"}' \
  --tokenizer-mode deepseek_v4 \
  --tool-call-parser deepseek_v4 \
  --enable-auto-tool-choice \
  --reasoning-parser deepseek_v4 \
  --additional-config '{"enable_cpu_binding": "true", "ascend_compilation_config":{"enable_npugraph_ex":true,"enable_static_kernel":false}}'

```
- 脚本路径：`/workspace/sh`
- 脚本文件名：`/workspace/sh/vllm.sh`
- 日志输出位置：`/workspace/log`
- 要求：第一次调用时，需要将该启动脚本输出到脚本路径下，并命名为 `vllm.sh`，由用户确认是否正确；后续调用不再重新生成，如需修改由用户修改启动文件。如果脚本路径或日志输出路径不存在，优先通过 `mkdir -p /workspace/sh /workspace/log` 创建路径。

## 3. 服务启动命令

填写可直接复用的完整启动命令，不要只填写命令片段。

```bash
mkdir -p /workspace/sh /workspace/log
nohup bash /workspace/sh/vllm.sh > /workspace/log/log-1.log 2>&1 &
```

命令拆解：

- 服务需要后台启动。
- 日志重定向：`/workspace/log/log-1.log`，每次重启需要增加日志编号，保证每次日志可以保留。

## 4. 服务启动成功标志


- 日志中存在如下字段: 
```
(ApiServer_0 pid=292745) INFO 06-03 01:35:17 [launcher.py:46] Route: /v1/chat/completions/render, Methods: POST
(ApiServer_0 pid=292745) INFO 06-03 01:35:17 [launcher.py:46] Route: /v1/completions/render, Methods: POST
(ApiServer_0 pid=292745) INFO:     Started server process [292745]
(ApiServer_0 pid=292745) INFO:     Waiting for application startup.
(ApiServer_0 pid=292745) INFO:     Application startup complete.

```
- 判定时不要精确匹配 pid 和时间，只检查关键字：
  - `Route: /v1/chat/completions`
  - `Route: /v1/completions`
  - `Started server process`
  - `Application startup complete`
- 健康检查命令：
```bash
curl -sS -w '\nHTTP_STATUS=%{http_code}\n' http://127.0.0.1:7000/v1/models
```
- 健康检查成功标志：`HTTP_STATUS=200`，且响应中包含模型列表或 `ds`。

## 5. 启动失败排查入口

- 首先查看的日志文件：`/workspace/log/log-N.log`
- Ascend/NPU 算子日志：`/root/ascend/log/debug/plog/`
- 端口占用检查：
```bash
ss -ltnp | grep ':7000'
```
- 模型路径检查：
```bash
ls -ld /mnt/weight/DeepSeek-V4-Flash-w8a8-mtp
```
- 网卡检查：
```bash
ip addr show enp162s0f0
```
- 常见失败关键字：`Address already in use`、`No such file or directory`、`ModuleNotFoundError`、`HCCL`、`NPU`、`timeout`、`Application startup failed`。

## 6. 停止进程

- 服务进程停止命令。该方式会强杀当前环境中的 Python 和 VLLM 相关进程，执行前确认当前机器只用于本轮 vllm-ascend 排查任务。
```bash
ps -ef | grep "python" | grep -v grep | awk '{print $2}' | xargs -t -i kill -9 {}
ps -ef | grep "VLLM" | grep -v grep | awk '{print $2}' | xargs -t -i kill -9 {}
```

## 7. 本轮启动记录

- 启动时间：`<每轮启动时填写>`
- 执行人或执行代理：`<每轮启动时填写>`
- 实际执行命令：`<每轮启动时填写>`
- 日志路径：`<每轮启动时填写>`
- 启动结果：`<成功 / 失败，每轮启动时填写>`
- 采用的成功判定依据：`<每轮启动时填写>`
