# accuracy-skills

`accuracy-skills` 是用于定位 vllm-ascend 精度问题的 Codex skill。它把排查过程固定为闭环：拉起服务、复现 badcase、收集日志和 dump、基于证据修改代码、重新验证。

适用场景包括：

- 模型输出不一致。
- logits 偏差。
- token 序列异常。
- Ascend 自定义算子或后端修改引入的精度回归。
- 需要反复重启 vllm-ascend 服务并对比修复效果。

## 目录结构

```text
accuracy-skills/
├── SKILL.md
├── README.md
├── agents/
│   └── openai.yaml
└── references/
    ├── accuracy-localization-guide.md
    ├── badcase-template.md
    ├── dump-metadata-template.json
    ├── problem-reproduction-guide.md
    ├── run-record-template.md
    └── service-startup-guide.md
```

## 使用方式

在任务中显式提到 `$accuracy-skills`，或描述 vllm-ascend 精度定位、服务复现、logits/token 差异、Ascend 后端精度回归等问题时使用本 skill。

示例：

```text
使用 $accuracy-skills 拉起 vllm-ascend 服务，复现这个 badcase，并定位 logits 偏差的首个分歧点。
```

## 工作流程

1. 进入现场：确认 vllm-ascend 仓库路径、模型路径、启动方式、badcase、期望输出或 golden。
2. 拉起服务：按 `references/service-startup-guide.md` 准备 `/workspace/sh/vllm.sh`，启动服务并记录日志。
3. 复现问题：按 `references/problem-reproduction-guide.md` 开启确定性计算，固定请求参数，复现 badcase。
4. 定位差异：按 `references/accuracy-localization-guide.md` 做 golden 对比或无 golden 自洽定位，优先找首个分歧 token、layer 或算子。
5. 修改代码：只修改一个明确假设对应的最小代码范围。
6. 循环验证：重新拉起服务，用同一 badcase 和同一判定标准比较结果。

## 记录模板

排查过程中优先复制并填写这些模板，保证每轮证据可以复查：

- `references/run-record-template.md`：服务启动记录。
- `references/badcase-template.md`：badcase、请求、golden 和复现结果记录。
- `references/dump-metadata-template.json`：dump run、环境、对比配置、dump 点和首个分歧证据。

## 关键原则

- 不要在只有“输出不对”的情况下直接改代码。
- 每轮只验证一个假设，避免同时改多个路径。
- 有 golden 时优先做同构 dump 对比；无 golden 时记录自洽定位证据。
- 大 tensor 不要无界 dump，先保存统计信息、topk 和少量 slice。
- 不回退用户已有改动，不做无关格式化或大范围重构。

## 输出要求

每轮结束后用中文汇报：

- 当前轮次和目标假设。
- 服务是否成功拉起。
- badcase 是否复现。
- 日志、dump 或 golden 对比中的关键证据。
- 修改了哪些文件以及原因。
- 精度现象是否改善、恶化或不变。
- 下一轮建议验证点。
