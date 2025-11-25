## 项目简介
本仓库示范如何用 Codex CLI 统一编排 “需求增强 → 代码生成 → 容器执行 → 结果验证” 的 R 自动化任务。仓库提供可复用的脚本、提示模板与 Docker 镜像，帮助团队快速搭建数据分析流水线并沉淀完整的迭代日志，便于审计和复盘。

## 当前存在的问题
- Dockerfile为示例，需要调整成合适的镜像资源
- 暂未测试

## 目录结构
| 路径 | 说明 |
| --- | --- |
| `config/` | Codex CLI 与容器的全局默认配置（如镜像、资源、重试次数）。 |
| `docker/` | R 运行镜像 Dockerfile 及 `docker-compose.yml`，确保环境可复现。 |
| `scripts/` | 自动化脚本，覆盖需求增强、代码生成、静态检查、容器执行与结果验证。 |
| `templates/` | Codex 提示模板与示例，用于保证生成内容结构统一。 |
| `docs/` | 架构与流程说明，可作为深入理解的参考资料。 |
| `tasks/` | 用户执行任务时的输入、生成脚本、日志与报告（运行时动态创建）。 |

## 工作流概览
1. **enhance**（`scripts/enhance-requirement.sh`）  
   基于原始需求生成增强需求与验收标准。
2. **generate**（`scripts/r-workflow-auto.sh` 内部）  
   渲染模板并调用 Codex 生成 R 脚本。
3. **execute**（`scripts/docker-utils.sh run`）  
   在 R 容器中运行最新脚本，同时采集日志与输出工件。
4. **validate**（`scripts/validate-result.sh`）  
   结合验收标准、运行日志及输出文件生成验证报告，可触发自动修复迭代。

详细数据流可参考 `docs/architecture.md`。

## 快速开始
### 前置条件
- 安装 [Codex CLI](https://github.com/openai/codex-cli) 并配置好 API 访问。
- 主机已安装 Docker，当前用户具备构建与运行镜像的权限。
- （可选）安装 `rsync` 与 `rg` 以获得更快的文件同步与扫描体验。

### 首次运行示例
```bash
# 1. 构建 R 运行镜像
./scripts/docker-utils.sh build

# 2. 准备任务目录与需求
mkdir -p tasks/sales-demo
cp docs/examples/requirement_raw.md tasks/sales-demo/requirement_raw.md

# 3. 启动自动化流水线（生成、执行、验证）
./scripts/r-workflow-auto.sh -t sales-demo --artifact output/report.csv
```
执行完成后，`tasks/sales-demo/` 将包含：
- `requirement_enhanced.md`、`acceptance_criteria.md`：增强需求与验收标准。
- `script_vXX.R`：按迭代编号保存的 R 脚本。
- `logs/`：Codex 交互日志、容器运行日志、静态检查与验证报告。
- `output/`：脚本产出（图表、报表、模型文件等）。

## 常用脚本速查
- `scripts/r-workflow-auto.sh`：端到端控制器，可控制起始阶段、最大迭代数、期望产出等。
- `scripts/check-r-code.sh`：独立运行的 R 静态检查器（语法、lintr、危险函数、依赖）。
- `scripts/docker-utils.sh`：封装镜像构建与容器执行，便于在 CI 或远程主机复用。
- `scripts/validate-result.sh`：基于验收标准和运行日志生成最终验证报告。

## Azure 测试资源需求
对于“快速验证”场景，仅需准备精简的 VM + ACR + Azure OpenAI 组合即可跑通流程：
| 资源 | 推荐配置 | 用途与说明 |
| --- | --- | --- |
| 资源组 | 专用 Resource Group（East Asia 或靠近数据区域） | 统一管理 VM、ACR 与 OpenAI 资源，方便清理。 |
| 计算 | Azure Linux VM（如 Standard D2s_v5，Ubuntu 22.04） | 在 VM 中安装 Docker、Codex CLI，即可本地运行 `scripts/r-workflow-auto.sh`；2 vCPU/8 GiB 满足默认容器需求。 |
| 镜像仓库 | Azure Container Registry（SKU Basic） | 存储 `codex-r-runner` 镜像：`docker tag codex-r-runner:latest <acr>.azurecr.io/codex-r-runner:latest && docker push ...`；VM 从 ACR 拉取即可，无需 AKS/ACI。 |
| Azure OpenAI | 包含 `gpt-5.1-codex` 部署的 Azure OpenAI 资源（East US/Sweden Central 等可用区） | Codex CLI 需配置 `AZURE_OPENAI_ENDPOINT`、`AZURE_OPENAI_KEY` 指向该模型部署，并在 `config/default.yaml` 中保持 `model: gpt-5.1-code-large` 或按需覆写。 |
| 网络 | 虚拟网络/NSG 允许 VM 出站访问 ACR、Azure OpenAI、CRAN 镜像源 | 确保 HTTPS 流量（443）畅通；若使用自定义代理，记得在 VM 环境变量中配置。 |
| 机密管理（可选） | Azure Key Vault | 存放 Azure OpenAI Key、ACR 凭据等敏感信息，VM 通过托管身份/CLI 拉取。 |

> **测试步骤建议**：在本地构建镜像 → 推送到 ACR → VM 上 `docker pull` 并 `git clone` 此仓库 → 配置 Codex CLI 与 Azure OpenAI endpoint → 运行 `./scripts/r-workflow-auto.sh -t <task>` 验证端到端流程。若需持久化任务数据，可以直接使用 VM 的数据盘或挂接托管磁盘即可。

## 参考资料
- `docs/architecture.md`：包含完整的系统架构、数据流与扩展点。
- `agents.md`：更细化的人工操作指引，便于将自动化流程落地到团队协作中。
