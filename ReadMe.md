## 项目简介
本仓库示范如何用 Codex CLI 统一编排 “需求增强 → 代码生成 → 容器执行 → 结果验证” 的 R 自动化任务。仓库提供可复用的脚本、提示模板与 Docker 镜像，帮助团队快速搭建数据分析流水线并沉淀完整的迭代日志，便于审计和复盘。

## 当前存在的问题
- Dockerfile为示例，需要调整成合适的镜像资源
- scripts/check-r-code.sh:70-90 在把脚本路径注入 Rscript -e "parse(file = '...')" 时直接拼接未转义的 '，若任务目录含有单引号会导致解析失败或执行错误。
- scripts/r-workflow-auto.sh 的需求增强阶段会执行增强文档中的任何“新建任务”指令（示例：tasks/iris-row-count/），目前缺少保护机制，易在未审核增强内容时误创建额外任务目录。

## 目录结构
| 路径 | 说明 |
| --- | --- |
| `docker/` | R 运行镜像 Dockerfile 及 `docker-compose.yml`，确保环境可复现。 |
| `scripts/` | 自动化脚本，覆盖需求增强、代码生成、静态检查、容器执行与结果验证。 |
| `templates/` | Codex 提示模板与示例，用于保证生成内容结构统一。 |
| `docs/` | 架构与流程说明，可作为深入理解的参考资料。 |
| `tasks/` | 用户执行任务时的输入、生成脚本、日志与报告（运行时动态创建，包含 `output/`、`logs/`、`tmp/`、`notes.md` 等）。 |

## 工作流概览
1. **enhance**  
   基于原始需求生成增强需求与验收标准。
2. **generate**   
   渲染模板并调用 Codex 生成 R 脚本；修复轮会把上一版脚本复制到 `script_vXX.R`，并通过 `sanitize_r_script` 清除 Markdown 包装，保证传给 R 的永远是可执行代码。
3. **execute**  
   在 R 容器中运行最新脚本，同时采集日志与输出工件；容器运行时会继承宿主 UID/GID，因此确保 `tasks/<TASK>/output`、`logs` 可写即可。
4. **validate**  
   `validate-result.sh` 先做本地存在性检查，再构造 Prompt 让 Codex 根据验收标准回顾运行日志与产物；可指定多个 `--artifact` 进行比对，失败将触发下一轮修复。

详细数据流可参考 `docs/architecture.md`。

## 快速开始
### 前置条件
- 安装 [Codex CLI](https://github.com/openai/codex) 并配置好 API 访问。
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
- `logs/`：Codex 交互日志、静态检查报告、容器运行日志、验证报告（缺少 `rg` 时也会在日志里给出警示）。
- `tmp/`：上下文、Prompt、验证快照（复现 Codex 输入的关键）。
- `output/`：脚本产出（图表、报表、模型文件等）。
- `notes.md`、`report.md`：任务历程与最终摘要。

> ⚠️ **提示**：增强阶段产出的需求文档可能会指示“新建别的子任务目录”（例如 `tasks/iris-row-count/`）。在继续自动迭代前，建议先审阅 `requirement_enhanced.md`，必要时手动调整后再执行 `r-workflow-auto.sh`，以免无意中在 `tasks/` 下创建额外目录。

## 常用脚本速查
- `scripts/r-workflow-auto.sh`：端到端控制器，支持 `--from-stage`、`--max-iters`、`--artifact`、`--skip-docker`、`CODEX_*_CMD_TEMPLATE` 等；修复迭代自动复制上一版脚本并清理 Markdown 片段。
- `scripts/enhance-requirement.sh`：读取 `requirement_raw.md`，渲染模板后调用 Codex 产出增强需求与验收标准，并把 Prompt/日志写入 `tasks/<TASK>/tmp`、`logs`。
- `scripts/check-r-code.sh`：运行 `parse()`、`lintr`、危险调用扫描与依赖探测，生成 Markdown 报告（若 `rg` 缺失会 fallback 到 `grep`）。
- `scripts/docker-utils.sh`：封装镜像构建 (`build`) 与脚本执行 (`run`)，运行脚本时会将任务目录挂载到 `/workspace` 并以宿主 UID/GID 执行 `Rscript`。
- `scripts/validate-result.sh`：校验运行日志、验收标准与产物是否存在，再结合 Codex 给出文字验收结论；本地检查失败会直接返回非零。

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
- `agents.md`：由codex init生成，方便codex对当前项目做更新。
