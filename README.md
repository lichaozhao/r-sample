## 项目简介
本仓库示范如何用 GitHub Copilot CLI 统一编排 “需求增强 → 代码生成 → 容器执行 → 结果验证” 的 R 自动化任务。仓库提供可复用的脚本、提示模板与 Docker 镜像，帮助团队快速搭建数据分析流水线并沉淀完整的迭代日志，便于审计和复盘。

## 当前存在的问题
- Dockerfile为示例，需要调整成合适的镜像资源
- scripts/check-r-code.sh:70-90 在把脚本路径注入 Rscript -e "parse(file = '...')" 时直接拼接未转义的 '，若任务目录含有单引号会导致解析失败或执行错误。
- scripts/r-workflow-auto.sh 的需求增强阶段会执行增强文档中的任何“新建任务”指令（示例：tasks/iris-row-count/），目前缺少保护机制，易在未审核增强内容时误创建额外任务目录。
- `config/default.yaml` 仅作为参考示例，当前脚本未自动读取，修改后不会影响实际运行配置。

## 目录结构
| 路径 | 说明 |
| --- | --- |
| `docker/` | R 运行镜像 Dockerfile 及 `docker-compose.yml`。 |
| `scripts/` | 自动化脚本，覆盖需求增强、代码生成、静态检查、容器执行与结果验证。 |
| `templates/` | Copilot 提示模板，保证生成内容结构统一。 |
| `docs/` | 架构与流程说明与示例。 |
| `config/` | 默认配置示例（镜像标签、模型名等），目前未被脚本自动加载。 |
| `analysis/` | 示例 R 分析脚本及检查报告，便于参考。 |
| `tasks/` | 用户执行任务时的输入、生成脚本、日志与报告（运行时动态创建，包含 `output/`、`logs/`、`tmp/`、`notes.md` 等）。 |
| `tmp/` | 运行过程产生的临时文件存放点（按需清理）。 |

## 工作流概览
1. **enhance**  
   `enhance-requirement.sh` 读取 `requirement_raw.md`，用模板驱动 Copilot 产出 `requirement_enhanced.md` 与 `acceptance_criteria.md`，中间 Prompt 保存在 `tasks/<TASK>/tmp/`。
2. **generate**   
   `r-workflow-auto.sh` 渲染模板并调用 Copilot 生成 R 脚本；修复轮会复制上一版脚本、插入 shebang、清理 Markdown 包装，并把上一轮脚本尾部 200 行及检查/运行/验证日志尾部写入上下文；静态检查失败、容器执行失败或验收失败都会进入下一轮，连续两次同类失败会终止。
3. **execute**  
   在 R 容器中运行最新脚本，同时采集日志与输出工件；容器运行时继承宿主 UID/GID 并挂载任务目录到 `/workspace`，确保 `tasks/<TASK>/output`、`logs` 可写即可。
4. **validate**  
   `validate-result.sh` 先做本地存在性检查（run 日志、验收标准、output 目录及额外 `--artifact` 路径），再让 Copilot 按验收标准核验文件存在性（默认不解析 run 日志内容）；失败将触发下一轮修复。

### 常用参数速查（`scripts/r-workflow-auto.sh`）
- `-t/--task`：任务名（必填），对应 `tasks/<NAME>/`。
- `-i/--input`、`-d/--data`：将需求文档或数据复制到任务目录。
- `--from-stage`、`--skip-docker`：从指定阶段开始或仅跑到静态检查。
- `--artifact`：声明需要验证存在的产物，可重复多次。
- `--notes`：自定义 `notes.md` 路径，便于单独记录。

详细数据流可参考 `docs/architecture.md`。

## 快速开始
### 前置条件
- 安装 [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli) 并完成登录。
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
./scripts/r-workflow-auto.sh -t sales-demo
```
执行完成后，`tasks/sales-demo/` 将包含：
- `requirement_enhanced.md`、`acceptance_criteria.md`：增强需求与验收标准。
- `script_vXX.R`：按迭代编号保存的 R 脚本。
- `logs/`：Copilot 交互日志、静态检查报告、容器运行日志、验证报告（缺少 `rg` 时也会在日志里给出警示）。
- `tmp/`：上下文、Prompt、验证快照（复现 Copilot 输入的关键）。
- `output/`：脚本产出（图表、报表、模型文件等）。
- `notes.md`、`report.md`：任务历程与最终摘要。

> ⚠️ **提示**：增强阶段产出的需求文档可能会指示“新建别的子任务目录”（例如 `tasks/iris-row-count/`）。在继续自动迭代前，建议先审阅 `requirement_enhanced.md`，必要时手动调整后再执行 `r-workflow-auto.sh`，以免无意中在 `tasks/` 下创建额外目录。

## 常用脚本速查
- `scripts/r-workflow-auto.sh`：端到端控制器，支持 `--from-stage`、`--max-iters`、`--artifact`、`--skip-docker`、`COPILOT_*_CMD_TEMPLATE` 等；修复迭代自动复制上一版脚本并清理 Markdown 片段。
- `scripts/enhance-requirement.sh`：读取 `requirement_raw.md`，渲染模板后调用 Copilot 产出增强需求与验收标准，并把 Prompt/日志写入 `tasks/<TASK>/tmp`、`logs`。
- `scripts/check-r-code.sh`：运行 `parse()`、`lintr`、危险调用扫描与依赖探测，生成 Markdown 报告（若 `rg` 缺失会 fallback 到 `grep`）。
- `scripts/docker-utils.sh`：封装镜像构建 (`build`) 与脚本执行 (`run`)，运行脚本时会将任务目录挂载到 `/workspace` 并以宿主 UID/GID 执行 `Rscript`。
- `scripts/validate-result.sh`：校验运行日志、验收标准与产物是否存在，再结合 Copilot 给出文字验收结论；本地检查失败会直接返回非零。

## Azure 测试资源需求
对于“快速验证”场景，仅需准备精简的 VM + ACR + Azure OpenAI 组合即可跑通流程：
| 资源 | 推荐配置 | 用途与说明 |
| --- | --- | --- |
| 资源组 | 专用 Resource Group（East Asia 或靠近数据区域） | 统一管理 VM、ACR 与 OpenAI 资源，方便清理。 |
| 计算 | Azure Linux VM（如 Standard D2s_v5，Ubuntu 22.04） | 在 VM 中安装 Docker、Copilot CLI，即可本地运行 `scripts/r-workflow-auto.sh`；2 vCPU/8 GiB 满足默认容器需求。 |
| 镜像仓库 | Azure Container Registry（SKU Basic） | 存储 `copilot-r-runner` 镜像：`docker tag copilot-r-runner:latest <acr>.azurecr.io/copilot-r-runner:latest && docker push ...`；VM 从 ACR 拉取即可，无需 AKS/ACI。 |
| GitHub Copilot | 可使用 GitHub Copilot CLI 的账号与网络访问 | Copilot CLI 通过 `copilot login` 登录；可在 `config/default.yaml` 记录默认模型（脚本不会自动读取）。 |
| 网络 | 虚拟网络/NSG 允许 VM 出站访问 ACR、GitHub/Copilot 服务、CRAN 镜像源 | 确保 HTTPS 流量（443）畅通；若使用自定义代理，记得在 VM 环境变量中配置。 |
| 机密管理（可选） | Azure Key Vault | 存放 ACR 凭据、代理凭据等敏感信息；Copilot CLI 登录凭据按 GitHub 官方方式管理。 |

> **测试步骤建议**：在本地构建镜像 → 推送到 ACR → VM 上 `docker pull` 并 `git clone` 此仓库 → 登录 Copilot CLI → 运行 `./scripts/r-workflow-auto.sh -t <task>` 验证端到端流程。若需持久化任务数据，可以直接使用 VM 的数据盘或挂接托管磁盘即可。

## 参考资料
- `docs/architecture.md`：包含完整的系统架构、数据流与扩展点。
- `AGENTS.md`：仓库级 Copilot 指令，方便 Copilot CLI 按当前项目约定执行更新。

## 后续计划
- 让 `config/default.yaml` 的默认镜像标签与模型参数可被脚本加载/覆盖，减少重复传参。
- 扩展 `validate-result.sh`，在 Copilot 或本地检查中解析运行日志内容，而不仅是文件存在性。
- 修复 `check-r-code.sh` 对含单引号路径的转义问题，避免 parse 阶段报错。
