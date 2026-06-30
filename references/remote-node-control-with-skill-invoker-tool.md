# 使用 skill-invoker-tool 协同远端节点

本文定义 `accuracy-skills` 与 `skill-invoker-tool` 的主从关系。精度定位主流程始终由 `accuracy-skills` 驱动，`skill-invoker-tool` 只承担远端目标容器控制能力。

## 1. 角色边界

`accuracy-skills` 负责：

- 组织“启动服务 -> 复现 badcase -> 收集证据 -> 修改假设 -> 重新验证”的闭环。
- 决定本轮要修改的启动参数、代码位置和日志观察范围。
- 在当前 Codex 节点保存 badcase payload、响应、golden 对比、run record 和 dump metadata。
- 基于日志、dump、topk、token 序列或 hidden states 证据判断精度现象。

`skill-invoker-tool` 负责：

- 通过 Ansible/SSH 连接远端目标容器。
- 在远端容器内修改启动脚本和代码。
- 在远端容器内查看日志、plog、进程和健康检查。
- 在多节点场景中同步执行启停命令。

`skill-invoker-tool` 不负责：

- 维护 badcase payload。
- 发送请求或保存响应。
- 执行 golden/dump 对比判断。
- 管理本轮排查记录和最终结论。

## 2. 默认拓扑

默认两端都是容器：

```text
Codex 当前容器
  - 运行 accuracy-skills 主流程
  - 使用 accuracy-skills 内置的 tools/skill-invoker-tool
  - 作为 Ansible 控制端

远端目标容器
  - 暴露 SSH 端口
  - Ansible 登录后已经位于容器内部
  - 承载远端 vllm-ascend 代码、启动脚本和日志
```

因此不要默认使用 `docker exec`、`docker cp` 或 Docker Compose。只有用户明确说明目标是 Docker 宿主机时，才使用 Docker 相关 playbook。

## 3. 远端目标配置

在 `tools/skill-invoker-tool/inventory.ini` 中配置远端容器：

```ini
[remote_containers]
target-a ansible_host=80.48.37.151 ansible_user=root

[remote_containers:vars]
ansible_port=18888
ansible_ssh_private_key_file=./ssh/id_ed25519
ansible_become=false
use_become=false
ansible_python_interpreter=/usr/bin/python3
```

在控制节点执行连通性检查：

```bash
cd <accuracy-skills>/tools/skill-invoker-tool
. .venv/bin/activate

ansible-playbook playbooks/ping.yml -e target_hosts=target-a
ansible-playbook playbooks/target-preflight.yml -e target_hosts=target-a
```

## 4. 修改远端启动脚本

当 accuracy 主流程判断需要修改远端启动环境时，使用 `skill-invoker-tool` 修改远端脚本。

开启确定性环境变量：

```bash
ansible-playbook playbooks/accuracy-startup-script-edit.yml \
  -e target_hosts=target-a
```

添加多个环境变量：

```bash
ansible-playbook playbooks/accuracy-startup-script-edit.yml \
  -e '{"target_hosts":"target-a","startup_script":"/workspace/sh/vllm.sh","startup_env":{"HCCL_DETERMINISTIC":"true","VLLM_ASCEND_ACCURACY_DUMP":"1"}}'
```

对于双节点脚本，例如 `/workspace/sh/double-node.sh`，显式传入脚本路径：

```bash
ansible-playbook playbooks/accuracy-startup-script-edit.yml \
  -e '{"target_hosts":"target-a","startup_script":"/workspace/sh/double-node.sh","startup_script_dir":"/workspace/sh","service_log_dir":"/workspace/sh","startup_env":{"HCCL_DETERMINISTIC":"true"}}'
```

如果远端脚本通过非交互 SSH 启动，脚本自身必须显式加载必要环境。常见配置：

```bash
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/cann-9.0.0/share/info/ascendnpu-ir/bin/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh

export PATH=/usr/local/python3.12.13/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/python3.12.13/lib:$LD_LIBRARY_PATH
```

## 5. 修改远端代码

当 accuracy 主流程判断需要在远端开启确定性代码开关时：

```bash
ansible-playbook playbooks/accuracy-enable-deterministic-code.yml \
  -e target_hosts=target-a
```

该 playbook 会在远端容器内修改：

```text
/workspace/vllm-ascend/vllm_ascend/worker/model_runner_v1.py
```

并在 `NPUModelRunner.__init__` 中幂等插入：

```python
torch.use_deterministic_algorithms(True)
```

如果远端仓库路径不同，传入：

```bash
ansible-playbook playbooks/accuracy-enable-deterministic-code.yml \
  -e '{"target_hosts":"target-a","vllm_ascend_repo":"/path/to/vllm-ascend"}'
```

查看远端仓库状态：

```bash
ansible-playbook playbooks/target-git-status.yml -e target_hosts=target-a
ansible-playbook playbooks/target-git-diff.yml -e target_hosts=target-a
```

## 6. 查看远端日志

查看最新服务日志：

```bash
ansible-playbook playbooks/target-log-tail.yml -e target_hosts=target-a
```

查看指定日志：

```bash
ansible-playbook playbooks/target-log-tail.yml \
  -e '{"target_hosts":"target-a","log_file":"/workspace/sh/double-node.log","tail_lines":200}'
```

搜索常见错误：

```bash
ansible-playbook playbooks/target-log-grep.yml \
  -e '{"target_hosts":"target-a","grep_paths":["/workspace/sh","/root/ascend/log/debug/plog"],"grep_patterns":["Traceback","RuntimeError","ImportError","HCCL","NPU","NaN","Inf"],"grep_max_count":100}'
```

## 7. 多节点启停

如果 `managed_hosts` 包含当前节点和远端节点，可以同步停止旧服务：

```bash
ansible-playbook playbooks/run-shell.yml \
  -e '{"target_hosts":"managed_hosts","allow_unsafe_shell":true,"command_to_run":"pkill -f '\''[V]LLM'\'' || true; pkill -f '\''[d]ouble-node.sh'\'' || true"}'
```

同步启动：

```bash
ansible-playbook playbooks/run-shell.yml \
  -e '{"target_hosts":"managed_hosts","allow_unsafe_shell":true,"command_chdir":"/workspace/sh","command_to_run":"nohup bash double-node.sh > double-node.log 2>&1 < /dev/null &"}'
```

检查两端进程和日志：

```bash
ansible-playbook playbooks/run-shell.yml \
  -e '{"target_hosts":"managed_hosts","allow_unsafe_shell":true,"command_chdir":"/workspace/sh","command_to_run":"echo PROCESS; pgrep -af '\''[d]ouble-node.sh|[v]llm serve'\'' || true; echo LOG; tail -n 120 double-node.log 2>/dev/null || true"}'
```

## 8. 典型失败与处理

`vllm: command not found`：

- 原因：非交互 SSH 环境没有包含 vLLM Python bin 目录。
- 处理：在启动脚本中添加 `export PATH=/usr/local/python3.12.13/bin:$PATH`。

`ImportError: libhccl.so`：

- 原因：CANN/HCCL 库路径没有加载。
- 处理：在启动脚本中 source CANN、Ascend NPU IR、ATB 的 `set_env.sh`。

`Connection refused` on `127.0.0.1:7000`：

- 若两端 `vllm serve` 进程仍在，通常表示模型仍在加载。
- 继续查看日志，不要在没有失败关键字时过早判定启动失败。

SSH `Permission denied`：

- 检查控制端公钥是否写入远端 `/root/.ssh/authorized_keys`。
- 检查远端权限：`/root/.ssh` 为 `700`，`authorized_keys` 为 `600`。
