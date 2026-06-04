# 精度问题定位手段

本文件用于沉淀 vllm-ascend 精度问题的定位方法。使用顺序是：先复现 badcase，再确认是否存在 golden；有 golden 时做同构 dump 对比，无 golden 时做自洽性和分层证据定位；最后基于证据修改代码。

## 1. 定位原则

- 先定位首个分歧点，再修改代码。
- 每轮只验证一个假设，避免同时改多个路径。
- 所有 dump 必须带上 run id、请求 id、step、layer id、rank、device、dtype、shape 和代码提交信息。
- 对比时优先看首个异常 token、首个异常 layer、首个异常算子。
- 大 tensor 不要无界 dump；先保存统计信息、topk、少量 slice，再按需要扩大范围。

## 2. 确认 golden 是否存在

golden 不一定存在。不要把“没有 golden”当作阻塞条件；它只影响定位策略。

可用 golden 可以来自 CPU、GPU、原生 vLLM、历史正确提交、已知正确的 vllm-ascend 版本或用户提供的正确输出。

若存在 golden，必须记录：

- golden 来源：分支、提交、环境、服务命令或用户提供结果。
- golden 与待测分支的差异：模型权重、tokenizer、配置、dtype、量化、并行参数、请求 payload。
- golden 是否能在当前 badcase 上稳定复现正确结果。

若不存在 golden，使用无 golden 定位路径：

- 同一分支重复运行 badcase，确认确定性是否稳定。
- 对比修改前后、不同配置、不同 batch size、prefill/decode、单卡/多卡、量化/非量化的结果变化。
- 通过 NaN/Inf、异常 topk、hidden_states 统计突变、dtype/shape 不变量破坏来定位异常层或异常算子。
- 对可疑小模块构造小输入，用 CPU/PyTorch 参考实现、朴素实现或单算子参考结果做局部 golden。
- 如果无法建立外部 golden，结论必须明确写为“无 golden，自洽定位证据为 ...”。

## 3. 有 golden 时的对齐要求

建立 golden 对比时必须保证：

- 模型权重、tokenizer、chat template、模型配置一致。
- 请求 payload 完全一致。
- 确定性配置一致。
- prefill、decode、batch size、并行配置、dtype、量化配置尽量一致；不能一致时必须记录差异。
- dump 的 tensor 名称、层号、token 位置、step、rank 和保存格式对齐。

golden 至少保留：

- 输入：prompt/messages、input_ids、position_ids、attention mask、sampling 参数。
- 输出：生成 token 序列、每步 topk token id、topk logits 或 logprobs。
- 中间结果：关键 layer 的 hidden_states，必要时扩展到 attention、MLP、MoE、KV cache。

### 3.1 在 golden 分支添加同构 dump 代码

如果 golden 来自另一个代码分支或历史正确提交，需要在 golden 分支和待测分支都加入同构 dump 代码，保证对比数据的生成逻辑一致。

操作要求：

1. 从待测分支整理一份只包含 dump/instrumentation 的补丁，不包含业务修复。
2. 将同一份补丁应用到 golden 分支；如果文件结构不同，只允许做等价适配，不能改变 dump 点语义。
3. 两个分支使用相同环境变量开关，例如 `VLLM_ASCEND_ACCURACY_DUMP=1`。
4. 两个分支使用相同 dump schema version、文件命名、tensor 名称、topk 的 k 值、dtype 转换、CPU 转储方式和统计指标。
5. 两个分支使用相同 badcase、请求参数、确定性配置、模型权重和 tokenizer。
6. 保存 metadata，记录 golden commit、待测 commit、dump 补丁 hash、badcase 名称、run id、rank、step、layer。

推荐将 dump 逻辑封装成公共 helper，两个分支都调用同一个 helper 语义：

```python
def dump_tensor(name, tensor, *, run_id, step, layer_id=None, rank=None, extra=None):
    # 只保存 detach 后的数据；大 tensor 优先保存统计信息和指定 slice。
    pass
```

必须避免以下情况：

- golden 分支和待测分支 dump 点不一致。
- 一个分支 dump fp32，另一个分支 dump bf16/fp16。
- 一个分支保存完整 tensor，另一个分支只保存统计信息。
- 一个分支保存 topk=5，另一个分支保存 topk=10。
- 文件名中缺少 step、layer、rank，导致对比时错位。
- 为了让补丁适配 golden 分支而顺手修改模型执行逻辑。

如果 golden 分支无法插入同构 dump，只能做输出级或局部模块级对比，并在结论中说明对比粒度受限。

## 4. 优先 dump 的内容

按从外到内的顺序 dump，逐步缩小范围。

### 4.1 请求级输入

- `input_ids`
- `position_ids`
- `attention_mask` 或 causal mask
- `seq_lens`
- `slot_mapping`
- `block_tables`
- sampling 参数：`temperature`、`top_p`、`top_k`、seed、`max_tokens`
- batch 组织信息：request id、batch id、prefill/decode 标识

若输入级信息已经和 golden 不一致，优先排查 tokenizer、chat template、position id、mask、batch 拼接和请求参数。

### 4.2 输出级结果

- 每步生成的 token id。
- 每步 topk token id。
- 每步 topk logits 或 logprobs。
- 有 golden 时记录 golden token 在当前 logits 中的 rank 和 logit；无 golden 时记录 badcase 异常 token、重复运行 topk 稳定性和 topk 间距。
- 首个分歧 token 的 step。

如果 hidden_states 对齐但 topk 或 token 选择不一致，优先排查 `lm_head`、logits processor、采样逻辑、temperature/top_p/top_k、随机种子和流式返回逻辑。

### 4.3 逐层 hidden_states

优先 dump 以下位置：

- embedding 输出。
- 每层输入 hidden_states。
- attention 前后的 hidden_states。
- MLP 前后的 hidden_states。
- residual add 后的 hidden_states。
- 每层输出 hidden_states。
- final norm 输出。
- lm_head 输入和输出 logits。

对比每层 hidden_states 时记录：

- `max_abs_diff`
- `mean_abs_diff`
- `max_rel_diff`
- cosine similarity
- NaN / Inf 数量
- min / max / mean
- 误差最大的 token 位置和 hidden 维度

定位策略：

- embedding 后已经分歧：排查 input_ids、embedding 权重、量化加载、dtype。
- 第 N 层输入一致、输出分歧：重点排查第 N 层内部 attention、MLP、norm、residual、MoE。
- 所有 layer hidden_states 基本一致但 logits 分歧：排查 final norm、lm_head、logits processor。
- prefill 正常、decode 分歧：重点排查 KV cache 写入/读取、slot_mapping、block table、position id 和 decode attention mask。

### 4.4 attention 路径

attention 相关问题优先 dump：

- q、k、v 投影输出。
- rope 前后的 q、k。
- attention mask。
- attention score 的统计信息。
- softmax 后概率统计。
- attention output。
- KV cache 写入前后的 k/v。
- decode 阶段读取出的 k/v。

常见判断：

- rope 后 q/k 分歧：排查 rope 参数、position id、rotary 维度、sin/cos cache、dtype。
- attention score 分歧但 q/k 基本一致：排查 mask、scale、layout、flash attention 或自定义 attention 算子。
- prefill 正常 decode 异常：优先排查 KV cache 地址、block table、slot mapping 和 cache dtype。

### 4.5 MLP / MoE 路径

MLP 或 MoE 相关问题优先 dump：

- gate/up/down projection 输出。
- activation 前后输出。
- expert routing topk expert id 和权重。
- 每个 token 分配到的 expert。
- all-to-all / all-reduce 前后 tensor 统计。
- dequant / quant 前后 tensor 和 scale。

常见判断：

- expert id 或 expert weight 分歧：排查 router logits、topk、grouped topk、rank 间同步和 MoE 路由实现。
- expert 输入一致但输出分歧：排查 expert 权重加载、量化 scale、matmul、activation。
- all-reduce 前一致后分歧：排查通信、rank 维度、HCCL 配置和并行切分。

### 4.6 量化和 dtype 路径

量化或 dtype 问题优先 dump：

- 权重 dtype、activation dtype、accumulator dtype。
- quant scale、zero point、group size。
- quant / dequant 前后 tensor 统计。
- matmul 输入输出统计。
- 是否发生 fp16、bf16、fp32、int8 之间的非预期 cast。

常见判断：

- 误差从量化层开始放大：排查 scale、group size、per-token/per-channel 维度、反量化顺序。
- 小误差逐层累积：排查 accumulation dtype、norm 精度、residual cast。
- 仅特定 batch size 或 seq len 异常：排查 tiling、padding、alignment 和动态 shape。

## 5. dump 实施建议

优先使用临时、可开关的 dump 逻辑，避免污染正式修复：

- 使用环境变量控制，例如 `VLLM_ASCEND_ACCURACY_DUMP=1`。
- dump 目录使用 `/workspace/log/accuracy_dumps/<run_id>/`。
- 文件名包含 `rank`、`step`、`layer`、`tensor_name`。
- tensor 保存前使用 `detach()`，必要时转 CPU。
- 大 tensor 优先保存统计信息、topk、指定 token slice；确认范围后再保存完整 tensor。
- dump 代码必须在最终修复前删除或受严格开关控制。

建议同时保存一个 metadata 文件，包含：

- badcase 名称和请求 payload。
- 代码提交和本轮修改 diff 摘要。
- 模型路径、dtype、并行参数、量化参数。
- dump 点列表。
- golden 来源；无 golden 时记录“无 golden”和替代定位依据。

## 6. 对比方法

有 golden 时按以下顺序执行：

1. 对比请求输入是否一致。
2. 对比生成 token 序列，找到首个分歧 step。
3. 对比该 step 的 topk token id 和 logits。
4. 对比 final hidden_states 和 logits。
5. 从 embedding 到每层输出逐层对比 hidden_states，找到首个异常 layer。
6. 在异常 layer 内部对比 attention、MLP、MoE、norm、residual。
7. 若异常只在 decode 出现，重点对比 KV cache、slot_mapping、block_tables、position_ids。

无 golden 时按以下顺序执行：

1. 重复运行同一 badcase，确认输出和 topk 是否稳定。
2. 对比开启/关闭可疑优化、不同 batch size、prefill/decode、单卡/多卡、量化/非量化的变化。
3. 检查输入、hidden_states、logits 的不变量：shape、dtype、NaN/Inf、数值范围、topk 间距。
4. 逐层 dump hidden_states，寻找统计突变层或 NaN/Inf 首次出现位置。
5. 对可疑模块构造局部参考实现或小输入单测，建立模块级 golden。
6. 将结论表述为自洽证据，不要声称已经和 golden 对齐。

对比结论要写成可验证形式：

- “第 N 层输入与 golden 对齐，第 N 层 attention output 开始分歧。”
- “hidden_states 对齐，logits topk 分歧，问题在 lm_head 或 logits processor。”
- “prefill 对齐，decode 第 1 步 KV cache 读取分歧。”
- “无 golden，重复运行稳定；第 N 层后 hidden_states 出现 NaN，问题收敛到第 N 层 norm/attention。”

## 7. 常见定位路径

- token 首个分歧但 topk 集合相近：检查采样参数、随机种子、logits processor。
- golden token 不在 topk 中：回退到 logits、final hidden_states 和逐层 hidden_states。
- 无 golden 但 topk 间距极小：不要只凭首 token 差异判断根因，优先查看 logits 差值和采样路径。
- 只有长序列异常：检查 position id、rope、mask、KV cache、block table、max model len。
- 只有多卡异常：检查 tensor parallel、data parallel、expert parallel、通信和 rank 间同步。
- 只有特定 batch 异常：检查 padding、seq_lens、slot_mapping、batch reorder。
- 只有量化模型异常：检查 quant/dequant、scale、zero point、matmul kernel、accumulation dtype。
- 输出中出现 NaN/Inf：反向定位首个 NaN/Inf layer 或算子，优先检查 norm、softmax、除法、exp、量化溢出。

## 8. 进入代码修改的条件

只有满足以下任一条件后，才进入代码修改：

- 已定位首个异常 layer 或算子。
- 已确认输入、hidden_states、logits 或 sampling 中的具体分歧点。
- 已有日志、dump 或对比结果支持一个明确假设。
- 无 golden 时，已有稳定复现、自洽不变量破坏或局部模块参考结果支持假设。

如果只有“输出不对”但没有中间证据，继续补充 dump、golden 对比或无 golden 自洽定位证据，不要直接改代码。
