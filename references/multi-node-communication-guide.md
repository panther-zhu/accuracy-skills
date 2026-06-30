# 双节点通信配置指导

本文说明如何配置两个容器节点，使控制节点可以通过 `accuracy-skills` 内置的 `skill-invoker-tool`
控制远端节点，并拉起双节点 vLLM 服务。

默认拓扑：

```text
控制节点容器 80.48.37.150
  - 安装 Codex 和 accuracy-skills
  - 使用 accuracy-skills 内置的 tools/skill-invoker-tool
  - 作为 Ansible 控制端
  - 作为 vLLM head/API 节点

远端节点容器 80.48.37.151
  - 通过 SSH 暴露 18888 端口
  - Ansible 登录后直接进入目标容器
  - 作为 vLLM headless/data-parallel worker 节点
```

## 1. 端口和路径约定

| 项目 | 默认值 | 说明 |
| --- | --- | --- |
| 控制节点 IP | `80.48.37.150` | vLLM head 节点地址 |
| 远端节点 IP | `80.48.37.151` | worker 节点地址 |
| 远端 SSH 端口 | `18888` | 控制节点通过该端口登录远端容器 |
| DP RPC 端口 | `13389` | 远端 worker 连接控制节点 |
| API 端口 | `7000` | 控制节点对外提供 vLLM API |
| 启动脚本目录 | `/workspace/sh` | 两个节点都需要存在 |
| 启动脚本 | `/workspace/sh/double-node.sh` | 两个节点分别维护自己的脚本 |
| 启动日志 | `/workspace/sh/double-node.log` | 两个节点各自生成 |

需要保证网络上至少这些链路可达：

```text
控制节点 -> 远端节点:18888
远端节点 -> 控制节点:13389
访问方   -> 控制节点:7000
```

## 2. 控制节点：准备内置 skill-invoker-tool

在控制节点容器执行：

```bash
cd <accuracy-skills>/tools/skill-invoker-tool

python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

生成控制节点 SSH key：

```bash
mkdir -p ./ssh
chmod 700 ./ssh

ssh-keygen -t ed25519 -f ./ssh/id_ed25519 -N "" -C "skill-invoker-tool"
```

查看控制节点公钥：

```bash
cat ./ssh/id_ed25519.pub
```

后续需要把这整行公钥写入远端节点的
`/root/.ssh/authorized_keys`。

## 3. 远端节点：配置 SSH 登录

在远端节点容器执行：

```bash
apt-get update
apt-get install -y openssh-server python3 bash grep sed gawk git curl

mkdir -p /run/sshd /root/.ssh /workspace/sh
chmod 700 /root/.ssh
```

把控制节点的公钥追加到远端节点：

```bash
echo '<控制节点 ssh/id_ed25519.pub 的完整内容>' >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

启动 SSH 服务：

```bash
/usr/sbin/sshd -D
```

如果远端容器由宿主机启动，需要确认宿主机已把容器 22 端口映射到
`18888`，例如：

```bash
docker run -d \
  --name target-a \
  -p 18888:22 \
  <image> \
  /usr/sbin/sshd -D
```

## 4. 控制节点：配置远端 inventory

在控制节点容器编辑：

```bash
cd <accuracy-skills>/tools/skill-invoker-tool
vi inventory.ini
```

配置内容示例：

```ini
[local_hosts]
local ansible_connection=local ansible_python_interpreter=/usr/bin/python3

[remote_containers]
target-a ansible_host=80.48.37.151 ansible_user=root

[managed_hosts:children]
local_hosts
remote_containers

[remote_containers:vars]
ansible_port=18888
ansible_ssh_private_key_file=./ssh/id_ed25519
ansible_become=false
use_become=false
ansible_python_interpreter=/usr/bin/python3
```

采集远端 SSH host key：

```bash
ssh-keyscan -p 18888 -H 80.48.37.151 >> known_hosts
```

检测 SSH/Ansible 连通：

```bash
. .venv/bin/activate

ansible-playbook playbooks/ping.yml -e target_hosts=target-a
ansible-playbook playbooks/target-preflight.yml -e target_hosts=target-a
```

成功时应看到：

```text
target-a: ok=1 unreachable=0 failed=0
```

## 5. 两个节点：准备 vLLM 启动环境

以下步骤需要分别在控制节点和远端节点容器内执行，或者由控制节点通过
Ansible 分发修改。

两个节点的 `/workspace/sh/double-node.sh` 都需要在脚本开头加载 CANN 和
Python 环境：

```bash
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/cann-9.0.0/share/info/ascendnpu-ir/bin/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh

export PATH=/usr/local/python3.12.13/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/python3.12.13/lib:$LD_LIBRARY_PATH
```

如果缺少 `PATH`，远端会报：

```text
vllm: command not found
```

如果缺少 CANN 环境，远端会报：

```text
ImportError: libhccl.so: cannot open shared object file
```

## 6. 控制节点：配置 head 节点启动参数

在控制节点容器的 `/workspace/sh/double-node.sh` 中，head/API 节点应包含：

```bash
vllm serve /mnt/share/weight/GLM-5.2-w8a8-0610 \
  --served-model-name glm \
  --port 7000 \
  --data-parallel-size 2 \
  --data-parallel-size-local 1 \
  --data-parallel-address 80.48.37.150 \
  --data-parallel-rpc-port 13389 \
  --tensor-parallel-size 8 \
  --enable-expert-parallel \
  --quantization ascend
```

控制节点不要加 `--headless`。控制节点负责监听 API 端口 `7000`，并作为
远端 worker 的 DP 协调地址。

## 7. 远端节点：配置 worker 节点启动参数

在远端节点容器的 `/workspace/sh/double-node.sh` 中，worker 节点应包含：

```bash
vllm serve /mnt/share/weight/GLM-5.2-w8a8-0610 \
  --headless \
  --served-model-name glm \
  --data-parallel-size 2 \
  --data-parallel-size-local 1 \
  --data-parallel-start-rank 1 \
  --data-parallel-address 80.48.37.150 \
  --data-parallel-rpc-port 13389 \
  --tensor-parallel-size 8 \
  --enable-expert-parallel \
  --quantization ascend
```

远端节点需要能够访问：

```text
80.48.37.150:13389
```

远端节点以 headless 模式加入控制节点，不对外提供主 API。

## 8. 控制节点：同时启停两个节点

以下命令都在控制节点容器执行。

停止两端旧进程：

```bash
cd <accuracy-skills>/tools/skill-invoker-tool
. .venv/bin/activate

ansible-playbook playbooks/run-shell.yml \
  -e '{"target_hosts":"managed_hosts","allow_unsafe_shell":true,"command_to_run":"pkill -f '\''[V]LLM'\'' || true; pkill -f '\''[d]ouble-node.sh'\'' || true"}'
```

同时启动两端服务：

```bash
ansible-playbook playbooks/run-shell.yml \
  -e '{"target_hosts":"managed_hosts","allow_unsafe_shell":true,"command_chdir":"/workspace/sh","command_to_run":"nohup bash double-node.sh > double-node.log 2>&1 < /dev/null &"}'
```

查看两端进程和日志：

```bash
ansible-playbook playbooks/run-shell.yml \
  -e '{"target_hosts":"managed_hosts","allow_unsafe_shell":true,"command_chdir":"/workspace/sh","command_to_run":"echo PROCESS; pgrep -af '\''[d]ouble-node.sh|[v]llm serve'\'' || true; echo LOG; tail -n 120 double-node.log 2>/dev/null || true"}'
```

## 9. 控制节点：健康检查

服务启动需要等待模型加载完成。确认控制节点 API 是否可用：

```bash
curl -sS -w '\nHTTP_STATUS=%{http_code}\n' \
  http://127.0.0.1:7000/v1/models
```

成功标志：

```text
HTTP_STATUS=200
```

如果短时间内返回：

```text
Connection refused
HTTP_STATUS=000
```

但两端 `vllm serve` 进程仍存在，通常表示服务还在加载，继续观察
`/workspace/sh/double-node.log`。

## 10. 常见问题

### 10.1 SSH 认证失败

现象：

```text
Permission denied (publickey,password)
```

处理：

1. 确认控制节点 `ssh/id_ed25519.pub` 已完整写入远端
   `/root/.ssh/authorized_keys`。
2. 确认远端权限：

```bash
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
```

### 10.2 Ansible 报 SSH 客户端配置错误

现象：

```text
/etc/ssh/ssh_config: Bad configuration option: permitrootlogin
```

处理：`ansible.cfg` 中应使用 `-F /dev/null`，避免读取系统坏配置：

```ini
[ssh_connection]
ssh_args = -F /dev/null -o ControlMaster=auto -o ControlPersist=60s -o ServerAliveInterval=30 -o UserKnownHostsFile=./known_hosts
```

### 10.3 远端 vllm 找不到

现象：

```text
vllm: command not found
```

处理：在远端 `/workspace/sh/double-node.sh` 开头添加：

```bash
export PATH=/usr/local/python3.12.13/bin:$PATH
```

### 10.4 远端缺少 libhccl.so

现象：

```text
ImportError: libhccl.so: cannot open shared object file
```

处理：在远端 `/workspace/sh/double-node.sh` 开头 source CANN 环境：

```bash
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/cann-9.0.0/share/info/ascendnpu-ir/bin/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh
```

### 10.5 API 端口暂时不通

现象：

```text
curl: (7) Failed to connect to 127.0.0.1 port 7000
HTTP_STATUS=000
```

处理：

1. 确认两端进程仍存在：

```bash
pgrep -af '[d]ouble-node.sh|[v]llm serve'
```

2. 查看两端日志：

```bash
tail -n 120 /workspace/sh/double-node.log
```

3. 若无失败关键字，等待模型加载完成后重试健康检查。
