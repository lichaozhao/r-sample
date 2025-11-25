# R 脚本智能生成与执行工作流 - 实现任务清单

## 项目目标
构建基于 Codex 的 R 代码自动化生成与执行系统，核心流程为：**用户输入 → Codex 需求增强 → 代码生成 → 代码检查 → Docker 容器执行 → 结果验证 → 自动修复迭代**。

---

## 核心工作流程

```
用户输入(数据 + 原始需求)
    ↓
Codex 需求增强(使用提示词模版)
    ↓
生成增强需求文档(requirement_enhanced.md)
    ↓
生成验收标准文档(acceptance_criteria.md)
    ↓
Codex 生成 R 代码
    ↓
代码静态检查(语法 + 最佳实践)
    ↓
进入执行循环：
    ┌────────────────────────────────┐
    │ 启动 Docker 容器               │
    │         ↓                      │
    │ 执行 R 脚本                    │
    │         ↓                      │
    │ 用Codex检查执行结果和对比验收标准  │
    │         ↓                      │
    │ 如有错误 → Codex 分析并修复    │
    │         ↓                      │
    │ 判断：成功 OR 达到循环上限     │
    └────────────────────────────────┘
```

---

## 第一阶段：Docker 基础设施

### 1.1 设计 Docker 镜像
- [ ] 创建 `docker/Dockerfile.r-runner`
  - 基于官方 `r-base` 镜像
  - 预装常用 R 包（tidyverse, ggplot2, data.table 等）
  - 配置国内镜像源加速包下载
  - 设置工作目录和权限
  - **检查标准**：
    - 镜像构建成功，大小合理（< 2GB）
    - 可成功执行基本 R 命令
    - 包含必要的系统依赖（libcurl, libxml2 等）

### 1.2 Docker 编排配置
- [ ] 创建 `docker-compose.yml`
  - 定义 R 运行环境服务
  - 配置卷挂载（tasks 目录、输出目录）
  - 设置资源限制（CPU、内存）
  - **检查标准**：
    - 可通过 `docker-compose up` 启动服务
    - 容器内可访问宿主机的任务数据
    - 容器执行后自动清理

### 1.3 容器管理脚本
- [ ] 创建 `scripts/docker-utils.sh`
  - 函数：`build_r_image()` - 构建/更新镜像
  - 函数：`run_r_in_container()` - 在容器中执行 R 脚本
  - 函数：`check_docker_available()` - 检查 Docker 环境
  - **检查标准**：
    - 脚本可独立调用，无外部依赖
    - 错误处理完善，输出清晰
    - 支持自定义镜像标签和容器名称

---

## 第二阶段：Codex 需求增强模块

### 2.1 需求增强提示词模版
- [ ] 创建 `templates/requirement-enhancement-prompt.md`
  - 模版结构：
    - 角色定义（你是数据分析专家...）
    - 任务说明（将用户需求细化为可执行规格）
    - 输出格式要求（结构化需求文档）
    - 示例（输入-输出对照）
  - **检查标准**：
    - 模版可处理模糊需求，输出明确的数据字段、计算逻辑、输出格式
    - 能够识别并补充遗漏的约束条件
    - 输出的需求文档有清晰的章节结构

### 2.2 验收标准生成模版
- [ ] 创建 `templates/acceptance-criteria-prompt.md`
  - 模版结构：
    - 基于增强需求生成可量化的验收条件
    - 包含：数据完整性检查、计算正确性验证、输出格式校验
    - 边界条件和异常情况测试点
  - **检查标准**：
    - 生成的验收标准可机器化验证（可转换为断言代码）
    - 覆盖正常路径和异常路径
    - 每条标准有明确的通过/失败判定方法

### 2.3 需求增强脚本
- [ ] 创建 `scripts/enhance-requirement.sh`
  - 输入：用户原始需求（`tasks/<TASK>/requirement_raw.md`）
  - 调用 Codex，使用需求增强模版
  - 输出：
    - `tasks/<TASK>/requirement_enhanced.md` - 增强需求文档
    - `tasks/<TASK>/acceptance_criteria.md` - 验收标准
  - **检查标准**：
    - 脚本可独立运行，参数清晰
    - 输出文档格式一致，易于后续解析
    - 记录 Codex 调用日志到 `logs/enhancement.log`

---

## 第三阶段：代码生成与检查

### 3.1 整合需求增强到代码生成
- [ ] 修改 `scripts/r-code-generate-and-run.sh`
  - 在代码生成前自动调用需求增强
  - 将 `requirement_enhanced.md` 和 `acceptance_criteria.md` 附加到生成 prompt
  - **检查标准**：
    - 生成的 R 代码包含需求文档中的所有关键步骤
    - 代码注释对应需求文档章节
    - 嵌入基本的数据验证代码（如 `stopifnot()`）

### 3.2 代码静态检查模块
- [ ] 创建 `scripts/check-r-code.sh`
  - 语法检查：`Rscript --vanilla -e "parse('script.R')"`
  - 风格检查：使用 `lintr` 包（如可用）
  - 安全检查：扫描危险函数（`system()`, `eval()`）
  - 依赖检查：提取并验证 `library()` 调用
  - **检查标准**：
    - 检查失败时输出详细的问题列表
    - 问题分级（错误/警告/建议）
    - 生成检查报告（`logs/code_check_v<XX>.md`）

### 3.3 集成代码检查到工作流
- [ ] 在主脚本中添加检查阶段
  - 代码生成后立即执行检查
  - 如果检查失败，将检查报告附加到下一轮 prompt
  - **检查标准**：
    - 检查报告格式适合 Codex 理解和修复
    - 严重错误（语法错误）直接触发重新生成，不进入容器执行
    - 警告级问题记录但不阻塞执行

---

## 第四阶段：容器化执行循环

### 4.1 改造容器执行逻辑
- [ ] 重写 `scripts/r-code-generate-and-run.sh` 的执行部分
  - 使用 Docker Compose 或直接调用 `docker run`
  - 挂载任务目录到容器 `/workspace`
  - 设置超时机制（防止无限循环）
  - **检查标准**：
    - 容器启动和清理自动化
    - 日志完整记录（stdout + stderr）
    - 容器内生成的文件正确回传到宿主机

### 4.2 执行结果验证
- [ ] 创建 `scripts/validate-result.sh`
  - 输入：执行日志（`logs/run_v<XX>.log`）、输出文件、验收标准
  - 验证逻辑：
    - 调用Codex来检查输出是否符合验收标准
    - 脚本退出码 = 0
    - 输出文件存在且非空
    - 对比验收标准中的具体指标（文件行数、列名、数值范围等）
  - 输出：验证报告（`logs/validation_v<XX>.md`）
  - **检查标准**：
    - 验证失败时明确指出不符合的标准项
    - 验证报告格式化，便于 Codex 分析
    - 支持部分通过的情况（区分致命错误和可接受偏差）

### 4.3 自动修复循环
- [ ] 实现智能迭代逻辑
  - 每次迭代：生成代码 → 检查 → 执行 → 验证
  - 失败时：
    - 收集检查报告、执行日志、验证报告
    - 生成修复 prompt：原始需求 + 代码 + 错误信息
    - 调用 Codex 生成修正版本
  - 循环终止条件：
    - 验证完全通过（SUCCESS）
    - 达到最大迭代次数（默认 5 次）
    - 连续 2 次产生相同错误（陷入死循环）
  - **检查标准**：
    - 每次迭代的所有工件保留（`script_v01.R` ~ `script_v05.R`）
    - `notes.md` 记录每次迭代的状态转换
    - 失败退出时生成诊断报告，指出根本原因

---

## 第五阶段：主控脚本重构

### 5.1 新主控脚本设计
- [ ] 创建 `scripts/r-workflow-auto.sh`
  - 命令行参数：
    - `-t, --task <NAME>` - 任务名称
    - `-i, --input <PATH>` - 用户输入需求文件
    - `-d, --data <PATH>` - 数据路径
    - `--max-iters <N>` - 最大迭代次数（默认 5）
    - `--skip-docker` - 跳过容器执行（仅生成代码）
    - `--from-stage <STAGE>` - 从指定阶段开始（enhance/generate/execute/validate）
  - **检查标准**：
    - 参数解析健壮，有默认值和校验
    - 各阶段可独立重跑
    - 进度输出清晰，易于跟踪

### 5.2 工作流编排
- [ ] 实现阶段化执行
  - 阶段 1：需求增强（`enhance-requirement.sh`）
  - 阶段 2：代码生成与检查（循环调用 Codex + `check-r-code.sh`）
  - 阶段 3：容器执行（调用 `docker-utils.sh`）
  - 阶段 4：结果验证（`validate-result.sh`）
  - 阶段 5：如失败，返回阶段 2（带错误上下文）
  - **检查标准**：
    - 每个阶段有明确的输入输出契约
    - 阶段间传递的数据格式一致
    - 支持断点续传（已完成的阶段不重复执行）

### 5.3 错误处理与报告
- [ ] 完善异常处理
  - 每个阶段的失败原因分类（配置错误/Codex 失败/执行失败/验证失败）
  - 生成最终报告（`tasks/<TASK>/report.md`）
    - 包含：需求文档、迭代历史、成功/失败原因、关键日志摘要
  - **检查标准**：
    - 报告可作为交付物或故障排查依据
    - 失败时提供可操作的修复建议
    - 成功时总结执行统计（迭代次数、耗时）

---

## 第六阶段：配置与可扩展性

### 6.1 配置文件设计
- [ ] 创建 `config/default.yaml`
  - Docker 配置：镜像名称、资源限制、超时时间
  - Codex 配置：模型名称、温度参数、最大 token 数
  - 验证配置：验收标准严格程度、容错阈值
  - **检查标准**：
    - YAML 格式规范，有注释说明
    - 配置项有合理默认值
    - 支持任务级配置覆盖全局配置

### 6.2 提示词模版库
- [ ] 组织模版目录结构
  ```
  templates/
  ├── requirement-enhancement-prompt.md
  ├── acceptance-criteria-prompt.md
  ├── code-generation-prompt.md
  ├── code-fix-prompt.md
  └── examples/
      ├── data-cleaning.md
      ├── statistical-analysis.md
      └── visualization.md
  ```
  - **检查标准**：
    - 每个模版有清晰的使用说明
    - 示例覆盖常见分析场景
    - 支持通过参数选择不同模版

### 6.3 插件化架构（可选）
- [ ] 设计扩展点
  - 自定义代码检查器（通过脚本接口）
  - 自定义验证器（通过配置文件）
  - 自定义 Codex 调用方式（支持其他 AI 服务）
  - **检查标准**：
    - 扩展接口文档清晰
    - 示例插件可运行
    - 不影响核心工作流稳定性

---

## 第七阶段：文档与测试

### 7.1 更新项目文档
- [ ] 重写 `ReadMe.md`
  - 新增 Docker 环境准备章节
  - 更新快速开始指南（使用新主控脚本）
  - 添加工作流程图（Mermaid 格式）
  - **检查标准**：
    - 新用户可按文档从零开始运行
    - 工作流程图与实际代码一致

- [ ] 重写 `agents.md`
  - 详细说明每个阶段的执行细节
  - 故障排查指南（常见错误及解决方法）
  - 高级用法（自定义模版、扩展验证器等）
  - **检查标准**：
    - 包含完整的命令示例
    - 常见问题有明确答案
    - 截图或日志示例辅助说明

- [ ] 创建 `docs/architecture.md`
  - 系统架构图
  - 各模块职责说明
  - 数据流向和状态转换
  - **检查标准**：
    - 便于新贡献者理解代码结构
    - 架构图与代码实现同步

### 7.2 测试用例
- [ ] 创建端到端测试任务
  - `tasks/test-simple/` - 简单描述性统计（必然成功）
  - `tasks/test-iterative/` - 需要 2-3 次迭代修复的任务
  - `tasks/test-failure/` - 故意设计的失败案例（测试错误处理）
  - **检查标准**：
    - 测试任务可通过脚本批量运行
    - 每个测试有预期结果说明
    - 测试覆盖主要分支逻辑

---

## 附录：目录结构与文件清单

### 完整目录结构
```
r-sample/
├── ReadMe.md                          # 项目主文档
├── agents.md                          # 使用指南
├── config/
│   └── default.yaml                   # 全局配置
├── docker/
│   ├── Dockerfile.r-runner            # R 运行环境镜像
│   └── docker-compose.yml             # 容器编排
├── scripts/
│   ├── r-workflow-auto.sh             # 新主控脚本
│   ├── enhance-requirement.sh         # 需求增强
│   ├── check-r-code.sh                # 代码检查
│   ├── validate-result.sh             # 结果验证
│   ├── docker-utils.sh                # Docker 工具函数
│   └── r-code-generate-and-run.sh     # 旧脚本（兼容保留）
├── templates/
│   ├── requirement-enhancement-prompt.md
│   ├── acceptance-criteria-prompt.md
│   ├── code-generation-prompt.md
│   ├── code-fix-prompt.md
│   └── examples/                      # 模版示例
├── tasks/
│   └── <TASK_NAME>/
│       ├── requirement_raw.md         # 用户原始需求
│       ├── requirement_enhanced.md    # Codex 增强需求
│       ├── acceptance_criteria.md     # 验收标准
│       ├── script_v01.R ~ v05.R       # 迭代版本
│       ├── script_final.R             # 最终脚本
│       ├── data/                      # 输入数据
│       ├── output/                    # 脚本输出
│       ├── logs/
│       │   ├── enhancement.log        # 需求增强日志
│       │   ├── codex_01.log ~ 05.log  # 代码生成日志
│       │   ├── code_check_01.md ~ 05.md  # 代码检查报告
│       │   ├── run_01.log ~ 05.log    # 容器执行日志
│       │   └── validation_01.md ~ 05.md  # 验证报告
│       ├── notes.md                   # 迭代记录
│       └── report.md                  # 最终报告
├── docs/
│   ├── architecture.md                # 架构文档
│   └── troubleshooting.md             # 故障排查
└── tests/
    ├── test-simple/                   # 简单测试任务
    ├── test-iterative/                # 迭代测试任务
    └── test-failure/                  # 失败测试任务
```

### 核心文件优先级

**第一优先级（必须实现）**
1. `docker/Dockerfile.r-runner` - Docker 基础设施
2. `scripts/docker-utils.sh` - 容器管理
3. `templates/requirement-enhancement-prompt.md` - 需求增强模版
4. `templates/acceptance-criteria-prompt.md` - 验收标准模版
5. `scripts/enhance-requirement.sh` - 需求增强脚本
6. `scripts/check-r-code.sh` - 代码检查
7. `scripts/validate-result.sh` - 结果验证
8. `scripts/r-workflow-auto.sh` - 新主控脚本

**第二优先级（增强功能）**
1. `docker-compose.yml` - 容器编排优化
2. `config/default.yaml` - 配置管理
3. `templates/code-fix-prompt.md` - 修复提示词
4. `docs/architecture.md` - 架构文档
5. 测试任务集

**第三优先级（锦上添花）**
1. 插件化扩展点
2. 更多示例模版
