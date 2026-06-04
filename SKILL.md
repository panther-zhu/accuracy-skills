---
name: accuracy-skills
description: 用于定位 vllm-ascend 精度问题的调试技能。适用于需要反复执行“拉起 vllm-ascend 服务、发送请求复现精度异常、查看服务日志、修改 vllm-ascend 代码并重新验证”的场景，尤其是排查模型输出不一致、logits 偏差、token 序列异常、算子或后端修改引入的精度回归。
---

# vllm-ascend 精度问题定位

## 工作原则

将排查过程组织为固定闭环：拉起服务、复现问题、修改代码、重新拉起服务。每一轮都保留可复查证据，避免凭印象判断精度变化。

优先使用仓库已有脚本、配置文件、测试用例和日志路径。不要在没有确认用途的情况下新增通用脚本或大范围重构。

每次只修改一个明确假设对应的最小代码范围。修改前记录当前现象，修改后用同一请求和同一判定标准比较结果。

## 进入现场

1. 确认用户给出的 vllm-ascend 仓库路径、模型路径、启动方式、复现请求和期望输出。
2. 若信息缺失，先从仓库内搜索 `README`、`docs`、`examples`、`scripts`、`tests`、`pytest`、`vllm serve`、`api_server`、`ASCEND`、`NPU` 等线索。
3. 记录本轮基线信息：代码分支、最近提交、关键环境变量、模型名称、dtype、并行参数、请求参数、日志位置。
4. 检查工作区是否已有用户改动。不得回退与当前排查无关的改动。

## 第一步：拉起服务

先读取并严格遵循服务启动指导：[references/service-startup-guide.md](references/service-startup-guide.md)。该文件是本技能的服务启动事实来源；若其中内容与本节不一致，以 `service-startup-guide.md` 为准。

### 1.1 检查启动依赖

启动前先确认当前环境安装了 `vllm` 和 `vllm-ascend`：

```bash
pip show vllm
pip show vllm-ascend
```

任一依赖不存在时，停止启动并向用户报错，不继续猜测启动命令。

### 1.2 准备启动脚本

使用 `service-startup-guide.md` 中的“服务启动脚本参考模板”作为启动脚本内容。第一次调用该技能时：

1. 创建脚本目录和日志目录：`mkdir -p /workspace/sh /workspace/log`。
2. 将启动脚本写入 `/workspace/sh/vllm.sh`。
3. 请用户确认 `/workspace/sh/vllm.sh` 内容是否正确。

后续调用时不要自动覆盖 `/workspace/sh/vllm.sh`；若脚本需要变化，由用户修改启动文件或明确授权更新。

启动脚本中的关键固定信息包括：

- 网卡：`enp162s0f0`，脚本会先检查该网卡是否存在。
- 模型路径：`/mnt/weight/xxx`。
- 服务名：`ds`。
- 服务地址：`0.0.0.0:7000`。
- 关键并行参数：`data-parallel-size=2`、`data-parallel-size-local=2`、`tensor-parallel-size=8`、`enable-expert-parallel`。
- 关键精度和后端参数：`quantization ascend`、`tokenizer-mode deepseek_v4`、`reasoning-parser deepseek_v4`、`ascend_compilation_config`。

### 1.3 清理旧服务

如果当前轮次需要重启服务，使用 `service-startup-guide.md` 中定义的停止命令。该命令会强杀当前环境中的 Python 和 VLLM 相关进程，执行前确认当前机器只用于本轮 vllm-ascend 排查任务。

```bash
ps -ef | grep "python" | grep -v grep | awk '{print $2}' | xargs -t -i kill -9 {}
ps -ef | grep "VLLM" | grep -v grep | awk '{print $2}' | xargs -t -i kill -9 {}
```

### 1.4 执行启动命令

按服务启动指导中的命令后台启动服务：

```bash
mkdir -p /workspace/sh /workspace/log
nohup bash /workspace/sh/vllm.sh > /workspace/log/log-1.log 2>&1 &
```

每次重启时递增日志编号，例如 `log-2.log`、`log-3.log`，确保每轮日志可追溯。启动后记录本轮启动时间、实际启动命令和日志路径。

### 1.5 判断启动成功

优先使用日志关键字判断服务是否启动成功。不要精确匹配 pid 和时间，只检查以下关键字：

- `Route: /v1/chat/completions`
- `Route: /v1/completions`
- `Started server process`
- `Application startup complete`

同时执行健康检查：

```bash
curl -sS -w '\nHTTP_STATUS=%{http_code}\n' http://127.0.0.1:7000/v1/models
```

健康检查成功标志为 `HTTP_STATUS=200`，且响应中包含模型列表或 `ds`。只有日志关键字或健康检查明确成功后，才进入第二步复现问题。

### 1.6 启动失败排查

启动失败时按以下顺序排查：

1. 查看本轮服务日志：`/workspace/log/log-N.log`。
2. 查看 Ascend/NPU 算子日志：`/root/ascend/log/debug/plog/`。
3. 检查端口占用：`ss -ltnp | grep ':7000'`。
4. 检查模型路径：`ls -ld /mnt/weight/DeepSeek-V4-Flash-w8a8-mtp`。
5. 检查网卡：`ip addr show enp162s0f0`。
6. 搜索常见失败关键字：`Address already in use`、`No such file or directory`、`ModuleNotFoundError`、`HCCL`、`NPU`、`timeout`、`Application startup failed`。

### 1.7 记录本轮启动结果

每轮启动后记录：

- 启动时间。
- 执行人或执行代理。
- 实际执行命令。
- 日志路径。
- 启动结果。
- 采用的成功判定依据。

## 第二步：复现问题

先读取并遵循问题复现指导：[references/problem-reproduction-guide.md](references/problem-reproduction-guide.md)。该文件是本技能的问题复现事实来源；它与服务启动指导隔离，不要为了开启复现条件而直接修改 `service-startup-guide.md`。

### 2.1 准备复现前置条件

复现前必须完成两个条件：

1. 开启确定性计算。
2. 准备好可重复执行的 badcase。

两个条件未完成时，不要发送请求判断精度问题。

### 2.2 开启确定性计算

按 `problem-reproduction-guide.md` 执行两步确定性配置。

第一步，只修改实际运行的启动脚本 `/workspace/sh/vllm.sh`，开启：

```bash
export HCCL_DETERMINISTIC=true
```

不要直接修改 `service-startup-guide.md` 中的启动模板。

第二步，在 vllm-ascend 仓库中定位：

```text
vllm_ascend/worker/model_runner_v1.py
```

在 `NPUModelRunner` 类的 `__init__` 方法中添加确定性算法开关：

```python
torch.use_deterministic_algorithms(True)
```

确认已导入 `torch`，避免重复添加。修改启动脚本或代码后，必须重新拉起服务，确保配置生效。

### 2.3 准备 badcase

复现请求必须来自明确的 badcase。若用户没有提供 badcase，先要求用户补充，或从当前问题描述中整理一个可复用 badcase。

badcase 至少包含：

- 请求接口：例如 `/v1/chat/completions` 或 `/v1/completions`。
- 请求 payload：包括 `model`、prompt/messages、`temperature`、`top_p`、`max_tokens`、seed、stream 等参数。
- 期望现象：错误输出、首个异常 token、logits 偏差、崩溃栈或与参考输出的不一致点。
- 参考结果或无 golden 说明：若有 CPU、GPU、原生 vLLM、历史正确版本或用户提供的正确输出，记录为参考结果；若没有 golden，记录无 golden 状态和计划采用的自洽定位依据。
- 复现命令或脚本：确保后续每一轮可以原样重放。
- 本轮服务日志路径：例如 `/workspace/log/log-N.log`。

整理 badcase 时固定所有会影响输出的参数。采样类请求优先设置确定性参数，例如固定 seed、使用低温或贪心解码；若问题只在采样下出现，保留原采样参数并明确记录。

### 2.4 发送请求复现

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

### 2.5 判断复现是否成立

判断精度问题时优先使用可量化标准：

- 生成 token 序列是否一致。
- logits、hidden states 或中间张量误差是否超过阈值。
- 首个分歧 token 的位置。
- 特定算子输入输出是否出现 NaN、Inf、溢出、截断或 dtype 非预期转换。
- 与 CPU、GPU、原生 vLLM 或历史正确提交的差异。

若 badcase 无法复现，先确认确定性计算是否已生效、服务是否加载了修改后的代码、请求参数是否与 badcase 完全一致，再判断是否需要重新准备 badcase。

## 第三步：定位并修改代码

先读取并遵循精度定位手段：[references/accuracy-localization-guide.md](references/accuracy-localization-guide.md)。不要在只有“输出不对”的情况下直接改代码；必须先通过 golden 对比、无 golden 自洽定位、dump 或日志证据定位到可验证的分歧点。

### 3.1 确认 golden 状态

在修改代码前先确认是否存在 golden。golden 可以来自 CPU、GPU、原生 vLLM、历史正确提交、已知正确的 vllm-ascend 版本或用户提供的正确输出，但 golden 不一定存在。

若存在 golden，必须确认 golden 来源、分支/提交、运行环境、请求 payload 和当前 badcase 是否一致。若 golden 来自另一个分支，必须在 golden 分支和待测分支都加入同构 dump 代码，保证 dump 点、tensor 名称、保存格式、topk 的 k 值、dtype 转换和统计指标一致。

若不存在 golden，不要阻塞定位。改用无 golden 自洽定位：

- 重复运行同一 badcase，确认确定性和输出稳定性。
- 对比不同配置、不同 batch size、prefill/decode、单卡/多卡、量化/非量化的变化。
- 检查 NaN/Inf、topk 间距、hidden_states 统计突变、dtype/shape 不变量破坏。
- 对可疑模块构造小输入或 CPU/PyTorch 参考实现，建立局部 golden。

无论是否存在 golden，都至少保留：

- badcase 请求 payload。
- 生成 token 序列。
- 每步 topk token id 和 topk logits 或 logprobs。
- 首个分歧 token 的 step。
- 必要的 hidden_states 或中间 tensor dump。

### 3.2 逐层 dump 定位

优先使用逐层 dump 找到首个分歧点。常用 dump 点包括：

- embedding 输出。
- 每层输入和输出 hidden_states。
- attention 前后 hidden_states。
- MLP / MoE 前后 hidden_states。
- final norm 输出。
- lm_head 输入、logits、topk token id。

对比 hidden_states 时记录 `max_abs_diff`、`mean_abs_diff`、`max_rel_diff`、cosine similarity、NaN / Inf 数量和误差最大位置。

定位时按以下顺序收敛：

1. 先对比请求输入、input_ids、position_ids、attention mask。
2. 再对比生成 token 序列和每步 topk token id。
3. 再从 embedding 到每层 hidden_states 逐层对比。
4. 找到首个异常 layer 后，在 layer 内细分 attention、MLP、MoE、norm、residual。
5. 若 prefill 正常 decode 异常，重点检查 KV cache、slot_mapping、block_tables、position_ids。

### 3.3 基于证据形成假设

基于 dump、日志、golden 对比或无 golden 自洽定位结果提出一个可验证假设，再修改代码。常见假设包括：

- dtype 转换或精度保持不符合预期。
- shape、stride、layout、padding、mask 或 position id 处理错误。
- Ascend 自定义算子入参、tiling、workspace、同步或边界条件错误。
- attention、rope、kv cache、sampling、logits processor 等路径与参考实现不一致。
- 多卡、rank、batch size、prefill/decode 切换或动态 shape 场景触发分支错误。
- 量化 scale、zero point、group size、accumulation dtype 或 dequant 顺序错误。
- MoE expert routing、expert weight、all-to-all / all-reduce 或 rank 间同步错误。

修改代码时遵守以下约束：

- 先定位调用链，再改最小代码范围。
- 优先增加临时诊断日志或断言验证假设；确认后再整理为正式修复。
- 不做无关格式化、不移动无关文件、不回退用户改动。
- 涉及算子或底层实现时，同步检查 host 侧参数、tiling、kernel 侧索引和边界处理。
- 涉及 Python 调度逻辑时，同步检查输入构造、默认参数、缓存状态和 eager/graph 两条路径。

## 循环验证

每次修改后重新执行完整闭环：

1. 停止上一轮服务或确认新代码会被加载。
2. 重新拉起服务。
3. 使用同一请求复现。
4. 查看同一范围日志、dump、golden 对比或无 golden 定位证据。
5. 对比本轮结果与基线结果。

若现象变化，记录变化点并收敛到更小范围。若现象不变，回到假设阶段，不要继续扩大修改范围，除非日志证据支持。

## 输出给用户

每轮结束后用中文汇报：

- 当前轮次和目标假设。
- 服务是否成功拉起。
- 复现请求是否成功发送。
- 日志中的关键证据。
- golden 对比或无 golden 定位证据、topk token id、hidden_states dump 或首个分歧点证据。
- 修改了哪些文件和原因。
- 精度现象是否改善、恶化或不变。
- 下一轮建议验证点。

最终结论必须包含：

- 根因或最可能根因。
- 修复位置。
- 验证命令和验证结果。
- 仍然存在的风险或未覆盖场景。
