# fx 全项目审查报告

审查日期：2026-11-06
基线 commit：`20f06ac1`（`Bound what a resumed session restores into memory`）
工作树状态：干净（审查开始时 `git status --short` 为空）
运行平台：Windows 11 / PowerShell 7 / Zig 0.17.0 / `./zig-out/bin/fx.exe`
审查方式：主代理 + 多个只读子代理分域并行，主代理对高影响结论做实机校准。

> 本文是审查结论与修复台账，不是已实施变更。所有子代理均为只读，未修改产品代码。
> 可信度标记：**实测** = 用构建产物或构建命令验证；**代码证据** = 有明确文件行号；
> **静态推断** = 未实机复现，需后续验证；**已撤回** = 经反证排除的假阳性。

## 0. 审查组织与可信度说明

### 0.1 代理与分工

本轮共派出 17 个子代理（全部是同一种 `subagent` 机制，没有第二种并行机制）：

| 类别 | 代理 | 说明 |
| --- | --- | --- |
| 原始 12 个审查域 | `mem-review`、`core-review`、`session-review`、`security-review`、`ui-review`、`protocol-review`、`cli-review`、`tools-review`、`ci-review`、`sdk-review`、`perf-review`、`portability-review` | 按模块边界分门别类 |
| 失败重派 2 个 | `session-review-2`、`portability-review-2` | 前两个因同一 shell 校验保护机制整轮报废，禁用 shell 后重派 |
| 用户实时反馈追加 3 个专题 | `shell-chain-review`、`runtime-mem-review`、`nesting-review` | 分别对应「双 shell 为何崩」「多子代理内存」「子代理嵌套与并发治理」 |

`cli-review` 曾自行再开 3 个二级子代理（`docs-audit`、`contract-audit`、`parser-audit`），后停止且未采用其结论。该现象本身是「子代理可无限嵌套」的实证，见 §8。

### 0.2 两个报废子代理是产品缺陷证据，不是编排噪音

`session-review` 与 `portability-review` 均以完全相同的失败结束：

```
Subagent failed: agent_turn_failed.
Partial result:
Repeated shell validation failures stopped the tool loop.
The invalid shell calls were not executed and produced no shell effect.
```

该文本来自仓库自身 `src/core/agent/runtime/orchestrator.zig:155`。主代理在同一台机器、同一个 pwsh 上调用一直成功，只有子代理反复撞校验并整轮报废。因此这两次失败与仓库代码相互印证，是本轮最高价值发现之一，详见 §7。

### 0.3 主代理做的实机校准

| 校准项 | 命令/动作 | 结果 |
| --- | --- | --- |
| 工作树与 HEAD | `git status --short` / `git log -1` | 干净，`20f06ac1` |
| 内存采样 | PowerShell `Get-Process -Id 49308` 三次 | WS 1535.4→1548.1→1561.7 MB；Private 6915.5→6824.1→6928.0 MB；Virtual ≈11.1 GB；Threads 312→306→308 |
| Windows 构建 | `zig build` | **编译/链接全部通过（5/7 步成功）**，仅 `install` 覆盖正在运行的 `zig-out\bin\fx.exe` 时 `AccessDenied` |
| 工具描述与 schema | 直接读 `src/builtins/tools.zig:76-125` | 确认描述示例与 schema 冲突 |

`zig build` 的实机结果推翻了 `portability-review-2` 初版里 5 条「Windows 直接编译失败」的 P0 结论；该代理已自我修订并撤回。此过程保留在 §6，作为审查可信度的一部分。

## 1. 结论总览

按「已确认且影响最大」排序。全部 14 个域已收口，共约 100 条发现。

| # | 域 | 结论 | 级别 | 证据 |
| --- | --- | --- | --- | --- |
| 1 | 子代理治理 | 嵌套深度**完全无限制**，实测单进程 231 个会话、深达 8 层；`subagent` 默认被继承，`starts_subagents` 恒为真 | P0 | 磁盘 `index.jsonl` 实测 + 代码 |
| 2 | 性能 | 活跃期 1ms 忙轮询，每轮还做全量 facts 收集（约 40 次子调用），解释「134 分钟烧 129.6 分钟 CPU」 | P0 | 实测 + 代码（主代理已核实） |
| 3 | 资源 | 线程池与 terminal backend 设计性不归还：停止全部代理后线程仍 174、WS 3758MB 20 秒不变 | P0 | 实测 + 代码 |
| 4 | 控制流 | `default_max_agent_steps = 0` 且 `allowsStep(0, n) == true`，**默认无步数上限**，nudge/continuation 也无预算 | P1 | 代码（主代理已核实） |
| 5 | Shell 链路 | 工具描述教模型写 `shell={"kind":"bash"}`，schema 只接受 `kind:"executable"`；子代理照描述调用必然失败，且 2 batch 即整轮终止、notice 不可操作 | P1 | 代码 + 2 个真实报废子代理 |
| 6 | 安全 | 审查证据无结构分隔，不可信文本可伪造 `action:` 段污染 auto 审查 | P1 | 代码 |
| 7 | 安全 | 一次路径 `always` 授权把 read 放大为 `workspace/**` 的四权限（含 edit） | P1 | 代码（主代理已核实） |
| 8 | UI | transcript 与工具输出不过滤 ESC，可注入 `\x1b[2J`/`\x1b[?1049h` 破坏终端 | P1 | 代码（主代理已核实） |
| 9 | 协议 | Anthropic 路径缺 JSON 深度检查，safe 构建下 >256 层直接 abort（其它三条路径都已加） | P1 | 代码 |
| 10 | 内存安全 | 退出超时后仍 destroy MCP sink，后台线程 use-after-free | P1 | 代码 |
| 11 | CI/发布 | `release.yml` 由 `push: main` 直接触发，不等 CI 结论即可打 tag、发 Release、更新 CDN `latest.txt` | P0 | 代码 |
| 12 | 跨平台 | Windows `zig build` 覆盖运行中的自身二进制失败（`AccessDenied`）；`detect-macos-need.sh` 对 Windows-only 改动误判无需 macOS | P1 | 实测 + 代码 |
| 13 | CLI/输出 | `--help` 绕过参数校验并 exit 0；`--json` 用法错误分裂成多套 shape；文本与 JSON 权限模式取值不一致 | P1/P2 | 实测约 50 用例 |
| 14 | 工具/文件 | `file_mutation.zig` 的 `unescapeCarried` 在首次匹配失败后无条件反转义并替换另一处文本 | P1 | 代码 |
| 15 | 性能 | `pacer.consume` 每 tick `@memmove` 整体左移，长回答 O(n²) | P1 | 代码（主代理已核实） |
| 16 | SDK | WASM HTTP 流泄漏；`node.js` fetch 清理 drain 分支永不可达；`fetchState` 单变量互相覆盖 | P1/P2 | 代码 |

**未发现（可信的否定结论）**：

- 静态审查**未找到**足以解释 GB 级占用的持续增长型内存泄漏；实测空闲 20 秒 WS/Private/Threads 完全不变，性质是「资源不归还」而非「泄漏」。
- 15 个 workflow 中 `pull_request_target` 为 0，未发现硬编码密钥。
- 发布目标矩阵（Linux x86_64/aarch64、macOS x86_64/aarch64）在 7 个文件中一致。
- corpus / shard weights / mac 平台列表 75 项全部一致，0 重复 0 缺失。
- Zig 0.17 的 comptime 平台裁剪正常工作，**不存在**「Windows 编译失败」类问题（曾误报 5 条 P0，已实机撤回，见 §6）。

## 2. CLI 与输出契约

来源：`cli-review`，47 个文件，10 条发现。用 `./zig-out/bin/fx.exe` + 独立临时 `FX_HOME` + `NO_COLOR=1` + `TERM=dumb` 实测约 50 个用例，记录 stdout/stderr/exit code。**实测**部分可信度高；代理单列了 7 项「未验证」未冒充结论。

### 2.1 P1：`--help` 让未知参数/flag 被静默忽略且 exit 0

- 证据：`src/main.zig:3826-3829`、`src/main.zig:4227-4229`、`src/core/cli/cli_surface.zig:1041-1050`、`:1563-1569`。帮助请求在解析命令参数之前直接渲染并返回 `.handled_success`。
- 实测：`fx help --bogus`、`fx --help extra`、`fx status --bogus --help`、`fx status --json --help` 全部 `exit=0`、stderr 空、`--bogus`/`extra`/`--json` 被忽略。
- 期望：未知 flag → `exit=2` 并点名坏输入；`--json` 时输出统一 JSON 失败快照。
- 修复：帮助请求先跑该命令的 `cli_flags` 校验，仅在参数合法时打印帮助；保留 `fx help` 冷启动快速路径。

### 2.2 P1：`--` 之后的 `--help` 仍被当成帮助 flag（代码推断，未实测）

- 证据：`src/builtins/commands.zig:221` 规定 `ask` 的 `--` 后全是 prompt 文本；`cli_surface.zig:1047-1049` 扫描整个 `args[1..]` 不检查 `--`；`cli_flags.zig:134-144` 本已正确实现 sentinel。
- 修复：`topLevelHelpRequest` 遇 `--` 停止扫描；补 E2E 断言 `fx ask -- --help` 不输出帮助。

### 2.3 P1：`fx ask --json` 用法错误输出另一套 shape 且无可操作消息

- 证据：`src/core/output/output_contracts.zig:49-66` 定义统一 `kind`/`error`/`code`；`src/core/cli/cli_ask.zig:1298-1303`、`:3964-4063` 输出完整 ask 结果字段并把错误名塞进 `error`。
- 实测：`fx ask --json --bogus x` → `exit=2`、`{"output":"","final_output":"","exit_code":2,...,"error":"InvalidAskArgs"}`；文本路径却明确写 `fx ask: unknown flag --bogus`。
- 修复：引入 typed `UsageProblem { message, code }`，文本与 JSON 从同一 snapshot 渲染；只增字段不改现有 `error` 类型（若必须改语义，先实现 `--json=v2`）。

### 2.4 P2：多个 `--json` 用法错误丢具体坏输入

- 证据：`cli_surface.zig:2974-2992`、`:3627-3643`；`cli_config.zig:82-99` 实际知道具体问题。
- 实测：`sessions --json extra` / `config get nonexistent_key --json` / `usage --period bogus --json` / `upgrade --channel bogus --json` 分别只给 `invalid arguments` / `unknown setting`，不点名 `extra`、`nonexistent_key`、`bogus`；文本路径会点名。

### 2.5 P2：`pr`/`issue`/`acp`/`login`/`completion` 带 `--json` 时不走统一 JSON 失败路径

- 证据：`src/builtins/commands.zig:97-105`、`:32-34`、`:433-441` 未声明 `--json`；`cli_surface.zig:2427-2439`、`:1584-1594`、`:1635-1643`、`:2338-2351` 只写 stderr 文本。
- 实测：`pr --json --bogus x` → `exit=2`、stderr `unknown flag --json`；`completion --json` → `unknown shell --json`，把合法格式开关误报成坏参数。

### 2.6 P2：文本与 JSON 对同一权限模式取值不一致

- 证据：`output_contracts.zig:1003` 用 `permissionModeDisplayLabel`（`full access`），`:1110` 用 `permissionModeLabel`（`full-access`）；`src/core/permissions/permissions.zig:100-110`。`.fx/skills/fx-cli-shape/references/rules.md:49` 要求各表面一致。
- 实测：`FX_PERMISSION_MODE=full-access fx status` 文本 `permission_mode=full access`，JSON `"permission_mode":"full-access"`。

### 2.7 P2：多个 JSON 失败快照缺 `code` 或 `kind` 错配

- 证据：`output_contracts.zig:2144-2150`（credits 无 `code`）、`:2252-2258`（upgrade 无 `code`）、`:1851-1856`（`sessions_convert` 把 skip code 塞进 `error`）；`cli_surface.zig:2098-2103` 把 `sessions convert` 用法错误派发成 `kind:"sessions"`，成功输出却是 `kind:"sessions_convert"`。
- 对照实测：`fx replay --json does-not-exist` 正确带 `code:"FileNotFound"`。

### 2.8 P2：`fx config schema --json` 与 help/spec 矛盾

- 证据：`src/builtins/commands.zig:450` 的 config usage 含 `[--json]`，`:69` 的 schema 子命令只声明 `--project`；`cli_config.zig:97-100` 拒绝 `format == .json` 并提示 `schema takes only --project`。
- 实测：`config schema --project --json` 被拒，但提示把合法组合误称为「只接受 `--project`」。

### 2.9 P3：补全忽略仍在使用的别名

- 证据：`src/builtins/commands.zig:383-386`（`balance`）、`:402-408`（`update`）；`src/core/cli/completion.zig:182-191` 只加 `spec.token`，从不加 `spec.aliases`。
- 实测：`fx completion bash` 输出 7958 字节，`update`/`balance` 出现 0 次；运行时 `fx update --help`、`fx balance --json` 均可用。

### 2.10 P3：大小写变体不提示相近命令，反而进入无 TTY 启动

- 实测：`fx HELP` → `exit=1`、stderr `fx requires an interactive terminal (TTY).`；`fx Status` → `exit=2` 且正确给 `did you mean status?`。
- 证据：`command_specs.zig:1416-1432` 大小写敏感匹配；`cli_flags.zig:268-280` `Nearest.max_edits=2`，`HELP`→`help` 需 4 次替换不触发。

### 2.11 该域已确认合规

`fx help` 快速路径在完整 config 初始化之前；未知 flag / `--limit 0|101|溢出值` / 缺 key 均 `exit=2`；真实失败 `exit=1`；stdout/stderr 分离；`stauts` 给 `did you mean status`。

### 2.12 该域未验证项（不参与定级）

SIGPIPE/管道中断（本机无 `C:\Program Files\Git\bin\bash.exe`）；§2.2 的 `--` sentinel 实机复现；冷启动 2ms 预算（需 Linux + hyperfine）；`fx config set` 在隔离 `FX_HOME` 下的 `DirectorySyncFailed`；`--json=v2` 在 `src/` 无实现；README 占位符；二级子代理结论未采用。

## 3. 工具与索引器

来源：`tools-review`，117 个文件，5 条发现。实跑 4 个边界检查脚本（`check-indexer-boundary.sh`、`check-compactor-boundary.sh`、`check-recovery-boundary.sh`、`check-agents-boundary.sh`）退出码均为 `0`。

### 3.1 P1：`unescapeCarried` 会静默替换未指定的文本

- 证据：`src/core/tooling/file_mutation.zig:1478-1486`、`src/core/shared/model_context_encoding.zig:272-287`。
- `old_string` 首次匹配失败后无条件把 `&lt;fx-context-update`、`&lt;fx-skill-used`、`&lt;scoped-rules...` 反转义回 `<...>`；只要反转义后串在文件中恰好出现一次就执行替换，不验证调用是否真来自被转义的工具输出。
- 触发：编辑含字面量 `&lt;fx-skill-used>` 的文档，且文件也有 `<fx-skill-used>`。
- 后果：违背 `old_string` 精确匹配语义，可能改错源码。
- 修复：仅对可证明来自 fx 转义工具结果的调用启用兼容路径；替换前明确报告发生了何种规范化。

### 3.2 P1：路径工具 active scope 未参与普通路径授权（需维护者确认是否属安全边界）

- 证据：`src/core/permissions/permissions.zig:295-303`、`src/core/workspace/workspace_access.zig:58-95`、`permissions.zig:1045-1074`。
- `permissionTargetsForCallInScope` 对非 `command_cwd` 目标退化为 `permissionTargetsForCall(primary_directory, ...)`，丢掉 `additional_directories`；`read_file`/`glob_files`/`grep_files` 在 `external_path_tools` 白名单中，绝对路径被标成 `external_intent` 后绕过 `ensurePathInsideWorkspace`；`read_file.zig:564-588` 测试明确把外部绝对路径读取成功作为预期。
- 触发：配置额外授权目录、`--no-additional-dirs`、移除某目录后。
- 修复：把 `AccessScope` 传入 `resolveFileToolPath` 并执行 `scope.contains`；权限提示展示真实目标。

### 3.3 P2：大工具结果经 `result_store` 时可能缺统一截断标记

- 证据：`src/core/agent/runtime/execution_memory.zig:948-975`、`src/core/tooling/tool_result_limits.zig:44-68`。启用 `tool_result_dir` 时走 `result_store.prepare*`，不再调 `prepareModelOutputWithTruncation`；`read_file` 的截断标记由工具自身生成，其他自由文本工具可能没有「已截断/原始字节数/上限/读取句柄」。
- 修复：`result_store.prepare*` 与 `prepareInlineResult` 共用一种截断标记；补启用/关闭持久结果存储两种测试。

### 3.4 P2：`read_file` 不区分 CRLF 与缺末尾换行

- 证据：`src/tools/filesystem/read_file.zig:350-357`、`:405-408`、`:429-434`。按 `\n` 切分保留尾部 `\r`；输出末尾统一追加 `\n`；`include_sentinel` 不覆盖这些差异。
- 后果：模型无法判断原文件是否以换行结束，直接拿带 `\r` 的行做 `edit_file.old_string` 会失败或把 CRLF 改成 LF。
- 修复：结果中增加 `line_ending` 与 `final_newline`；补 CRLF / 孤立 CR / 无末尾换行 / 长行截断往返测试。

### 3.5 P2：`grep_files` 与 `@` 补全未下传 active scope 判断符号链接目标

- 证据：`src/core/workspace/grep_search.zig:522-527`、`src/core/workspace/path_completion.zig:64-76`。`resolveDirectoryEntryTarget` 只在 `sym_link` 且 realpath 落在 `workspace_root` 之外时跳过，不检查 `scope.additionalRootForPath`。
- 修复：把 `AccessScope` 下传，统一用 `scope.contains(canonical_target)`。

### 3.6 该域已确认合规

索引器仅经 `indexer.zig` 前门、只导入 `std`/自身/`io.zig`/`debug_trace.zig`、不启动进程；`@`-completion / `glob_files` / `grep_files` 生产代码不启动进程；`edit_file` 是单一唯一字符串替换而非 patch；`write_file`/`edit_file` 用临时文件 + `rename` 并有 preimage/identity/traversal 复验（`:630-632` 自述最终检查与 rename 间仍有平台竞争窗口）；`read_file` 有 10 MiB 快照 / 256 KiB 模型输出 / 2000 行限制；`grep_search` 64 KiB chunk + 200/2000 结果上限 + 跳过 NUL/非法 UTF-8；shell 有 `timeout_ms`、yield/wait ceiling、进程树信号、输出上限。

## 4. 测试与 CI

来源：`ci-review`，18 条发现。核对 15 个 workflow、`scripts/`、`build.zig`、benchmarks、TLA+、fuzz、E2E 元数据。

### 4.1 P0：Release 不等 CI，且可与 CI 从同一次 `push: main` 并行发布

- 证据：`.github/workflows/release.yml:3-5`（`push: branches: [main]` 直接触发）；`:309-311` 的 `release` job 只依赖 `check-version`/`package-linux`/`build-macos-x86_64`/`sign-macos-arm64`，无 `workflow_run`、checks API 或 conclusion gate；`.github/workflows/ci.yml:13-15` 同样由 `push: main` 触发；`release.yml:325-332` 推 tag、`:344-351` 建 Release、`:353-392` 传 CDN 与 `latest.txt`。
- 与 `AGENTS.md`「精确 commit 的 `Build & Test`、`E2E (deterministic)`、`Shellcheck`、`Startup Latency`、`macOS arm64` 全绿才算有效 CI」冲突。
- 后果：CI 未完或失败时仍可发布稳定版。
- 修复：改为 `workflow_run` 由 CI 成功触发，或加 gate job 按 exact SHA 查询并确认所有必需 check 成功。

### 4.2 P1：Release 先推 tag 后校验 CHANGELOG markers

- 证据：`release.yml:325-332` 先 `git tag` + `git push origin`，`:334-341` 之后才 `awk` 抽 `<!-- release:start -->`/`<!-- release:end -->` 且只检查行数 ≥2。
- 后果：CHANGELOG 格式错误时 tag 已在远端，重试因 tag 已存在走 `needed=false`，可能需人工删 tag 或发布错误 notes。
- 修复：把 marker 数量、首个 `## ${VERSION}` heading、旧 entry 无 markers 的校验前移到 `check-version`。

### 4.3 P1：`detect-ci-need.sh` 漏掉 `src/wasm_term_main.zig`

- 证据：`scripts/detect-ci-need.sh:120-121` 只匹配 `src/napi_*.zig | src/wasm_core_main.zig`；`build.zig:451-455` 把 term WASM 入口指向 `wasm_term_main.zig`；`AGENTS.md:99` 把三个入口并列。
- 后果：只改 term WASM 入口的 PR 不触发 libfx 长模型检查。

### 4.4 P1：macOS detector 漏掉子目录中的平台分支

- 证据：`scripts/detect-macos-need.sh:105-108` 只扫 `tests/e2e/*.ts` 一级；`tests/e2e/render-lab/native.ts:708` 有 `process.platform !== "darwin"`；`macos.yml:55-58` 在 `needed != true` 时跳过并在 `:212` 直接 `exit 0`。
- 修复：扫描扩到 `tests/e2e/**/*.ts`，补 `ci-shards.test.ts` 子目录用例。

### 4.5 P1：macOS E2E 运行声音测试且未强制 `FX_SOUND=0`

- 证据：`macos-platform-tests.json:9` 含 `tui-command-permissions.test.ts`，该文件 `:1610` 发 `/sound on`；`notifications.test.ts:63-65` 主动清掉 `FX_SOUND`；`ci.yml:877`/`bench.yml:309` 的 `FX_SOUND=0` 不覆盖 `macos.yml`。
- `AGENTS.md:278` 明确说 macOS 上声音播放可能压垮机器。

### 4.6 P1：Release artifacts 缺完整性断言

- 证据：`release.yml:319-323` `download-artifact` 用 `pattern: fx-*` + `merge-multiple: true` 未声明期望清单；`:349-351` 用 glob 附加；`:362-381` CDN 循环 `[ -f "$FILE" ] || continue` 不检查数量或 checksum。
- 修复：显式断言 4 平台 archive + 4 `.sha256` 均存在、非空、`sha256sum -c` 通过。

### 4.7 P1：smoke test 只覆盖 3 个无 TTY 命令

- 证据：`scripts/smoke-binary.sh:35-37` 仅 `--version`、`help`、`status --json`；被 `ci.yml:161-162`、`macos.yml:102-103`、`binary-size.yml:98-103` 当作 fresh binary smoke。
- 与 `AGENTS.md:16-25`「必须运行 binary 并做真实交互」冲突。能打印 `--version` 但进 TUI 即崩的二进制可通过。

### 4.8 P2：3 个 fuzz 测试未注册

- `src/core/mcp_host/credentials.zig:575-576`、`src/mcp/auth/client.zig:1057-1058`、`src/ui/footer/mcp_host_menu_presentation.zig:899-900`。源码共 51 个 `testing.fuzz`，`tests/fuzz/targets.json` 只有 48 个；`src/fuzz_targets.zig` 未导入这三项。
- 修复：补 registry + corpus 目录 + import；加「源码 fuzz 集合 == registry 集合」CI 校验。

### 4.9 P2：`ci.yml` 无顶层 `permissions`，95 个第三方 action 用 mutable tag

- `ci.yml:1-23` 无 `permissions:`；197 个 `uses:` 中 95 个远程 action 用 `@v4`/`@v2` 等；`release.yml`、`publish-libfx.yml`、PGSO 已用 40 字符 SHA pin。`ci.yml:988` 把 `AI_GATEWAY_API_KEY` 注入 live ACP 测试进程。
- 修复：`permissions: contents: read`；统一 pin SHA；secret 限定到最小 step。

### 4.10 P2：`cdn-backfill.yml` 把 dispatch 输入直接插入 shell

- 证据：`cdn-backfill.yml:37,40-41,58,130,147` 把 `inputs.version`、`inputs.dry-run`、`steps.versions.outputs.list` 直接写进 shell 字符串 / here-doc，而非 `env:`；`:53,145` 持有 `BLOB_READ_WRITE_TOKEN`。
- 后果：有 dispatch 权限者可构造 shell 片段借 blob 写 token 执行任意命令、覆盖 CDN 路径或 `latest.txt`。
- 修复：全部经 `env:` 传；version 用 `^v[0-9]+\.[0-9]+\.[0-9]+$` 白名单。
- 补充：15 个 workflow 中 `pull_request_target` 为 0。

### 4.11 P2：边界脚本正则可被合法 Zig 语法绕过

- 证据：4 个 `check-*-boundary.sh` 都要求 `@import\("` 紧连；代理用临时文件实跑 `zig test` 验证 `@import ("std")` 可编译（`1/1 ... OK`，exit 0，临时文件已删）。`check-compactor-boundary.sh` 的 `git grep` 未带 `--untracked`（其余三个带了）；多个脚本用 `awk '/^test "/ { exit }'` 只检查首个测试块之前。
- 修复：改用 Zig AST / build step 解析 import；至少允许空白、统一 `--untracked`、不依赖首个 `test "` 截断。

### 4.12 P2：Shellcheck / spell / format 覆盖不完整

- `ci.yml:43-44` 的 `zig fmt --check` 只查 `src/`，不含 `build.zig` 或 `benchmarks/*.zig`；`:940-956` shellcheck 白名单只有 10 个脚本，仓库有 35 个 `.sh`；签名脚本、20 个 TLA+ `check.sh`、`tests/tla/lib/*.sh` 均不在列；无 `actionlint`/拼写检查。

### 4.13 P2：Benchmark 预算表含未测量命令

- `AGENTS.md:412` 说测 6 条 CLI 路径；`benchmarks/startup.sh:96-152` 实际测 5 个 fx 命令 + 1 个 process baseline，没有 `background --json`；`benchmarks/check_budgets.py:10-17` 却含 `fx background --json: 0.002`。`bench.yml:55-58` 用 `wget` 下 hyperfine `.deb` 未校验 checksum。
- 修复：补测该命令或删预算条目并统一文档；固定 hyperfine checksum；用对照/分位数降噪。

### 4.14 P3：其他

- `build.zig:100-106` 在 Windows 跳过 POSIX suites，`zig build test` 只剩 benchmark policy tests，但 `AGENTS.md:258-260` 未说明，且 15 个 workflow 无 `runs-on: windows-*`。
- `ci.yml:869-916` 的 `e2e_conformance` 引用不存在的 `steps.zig.outputs.cache-key`/`cache-hit`（该 job 没有 `id: zig` 的 Setup Zig step）。
- live ACP / dev-release 的 secret 暴露面未最小化（job 级 env 被所有后续 step 继承）。

### 4.15 该域已确认合规

75 个根 E2E 文件与 `ci-shard-weights.json`（75 条、0 重复/缺失/过期）、`scripts/pgso/corpus.json`（30 training + 32 verification + 13 exclusions = 75）、`macos-platform-tests.json`（17 条）全部一致；fuzz registry 自身 48 个唯一 target 且 corpus 目录均对应；当前 `CHANGELOG.md` 与 `src/main.zig:10` 都是 `0.0.16`，markers 恰好一对；E2E 单文件失败重试一次且仅重试通过发 warning；`AGENTS.md` 要求的 5 个 check 名均存在。

## 5. 跨平台与构建（已实机校准）

来源：`portability-review-2`，98 个文件。初版报 12 条（含 5 条 P0「Windows 直接编译失败」），经主代理 `zig build` 实机反证后自我修订为 **0 P0 / 6 P1 / 1 P3，共 7 条**。

### 5.1 已撤回的假阳性（不要修）

`src/tools/web/http_fetch.zig`、`src/core/mcp_host/mcp_call_bridge.zig`、`src/core/shared/readiness.zig`、`src/core/execution/command_runner.zig` / `mcp_host/login.zig` / `ui/shell_runtime.zig`、`src/core/shared/io.zig` 的 `std.posix.poll` / `termios` / `c_cc` 被称为 Windows 编译失败。

- 反证：`zig build` 编译、链接全部通过；`zig-out/bin/fx.exe` 此刻正在本机运行。
- 原因：Zig 0.17 的 `if (comptime is_windows)` / `if (builtin.target.os.tag == .windows)` 会裁剪后续分支，未被引用的顶层声明受惰性分析保护，`@compileError` 不进入 Windows 类型检查。
- 同样撤回 `src/core/shared/local_time.zig:142-159` 的「UCRT 链接失败/ABI 崩溃」：`std.c.time_t` 在 MSVC 为 `void`，`if (comptime @typeInfo(std.c.time_t) != .int) return .utc` 提前返回。残余仅为「Windows 本地时间静默回退 UTC」，降 P3。

### 5.2 P1（实测）：`zig build` 无法覆盖正在运行的自身二进制

- 证据：`zig build` 输出 `Build Summary: 5/7 steps succeeded (1 failed)`，唯一失败 `error: failed updating file from .zig-cache\...\fx.exe to zig-out\bin\fx.exe: AccessDenied`；`build.zig:94` 的 `b.installArtifact(exe)` 在 Windows 目标文件被当前进程占用时拒绝覆盖。
- `zig-out/bin/` 下另有 3 个 `fx.running.*.exe` 副本，说明 fx 自己有热替换机制，但 `zig build` 路径没有。
- 后果：Windows 开发验证回路被阻断（先构建→运行→再构建即失败）。
- 修复：Windows 文档提示先退出运行中的 fx；或构建时用临时 install prefix / `fx-dev.exe` 产物名；Windows CI 增加「运行中二进制占用」用例。

### 5.3 P1：`SetConsoleOutputCP` 保存/恢复不全，失败即启动失败

- 证据：`src/core/shared/term_mode.zig:100,177,202,206`。`enableRaw` 调 `SetConsoleOutputCP(65001)`，失败时 `restore(...)` 后返回 `error.Unexpected`；`GetConsoleOutputCP` 已声明但全文件无调用，`restore` 只恢复 input/output mode 不恢复原输出代码页。
- 后果：旧 ConHost / 重定向 / 受限会话下 TUI 启动失败，且留下全局控制台副作用。
- 修复：`Saved` 保存并恢复原 CP；把 CP 设置失败降级为非 ASCII 显示诊断而非启动失败。

### 5.4 P1：升级器声明 Windows 目标但发布矩阵无 Windows

- 证据：`src/core/upgrade/upgrade_helpers.zig:62,66,83` 生成 `windows-x86_64`/`windows-aarch64`；`:326` 解包固定找 `{s}/fx`；`:391` `extractTarGz` 调外部 `tar`；`binary-size.yml:29-48`、`dev-release.yml:28-35`、`cdn-backfill.yml:24` 只有 4 个 Linux/macOS 目标。
- 后果：Windows 自构建二进制跑 `fx upgrade` 会请求不存在的资源；即使存在也缺 `tar` 且应找 `fx.exe`。
- 修复：未正式支持 Windows 时让 `platformFromTarget()` 对 `.windows` 返回 `null` 并给明确文案；若支持则补构建/签名/打包、`.zip` 解包抽象、`.exe` 映射、不依赖外部 tar 的解包器。

### 5.5 P1：`renameAbsolute` / `delete+create` 覆盖运行中 exe（与 §5.2 同源）

- 证据：`src/core/shared/io.zig:1234,1266`、`upgrade_helpers.zig:391-425`、`src/core/session_manager/storage.zig:324-354`（`syncDir` 在 Windows 直接 `return`）。
- 后果：Windows 上目标被占用时覆盖失败；先删原二进制再复制会留下「旧程序已删、新程序未写完」窗口；目录项持久性无屏障。
- 修复：Windows 用 `MoveFileExW(MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)` 或 `ReplaceFileW` 并保留备份回滚。

### 5.6 P1：`detect-macos-need.sh` 把 Windows-only diff 判为无需 macOS

- 证据：`scripts/detect-macos-need.sh:52,96-97` 的 Zig 关键字不含 `.windows`，测试 `test_detect_macos_need.py:87,90` 还把仅含 Windows 分支断言 `needed=false`；`macos.yml:58` 在 `needed != true` 跳过并在 `:212` `exit 0`。
- 后果：改了只含 `.windows` 分支但影响共享 `else` 路径的文件，Linux CI 通过 + macOS 直接跳过，macOS/Linux arm64 用户可能遇到回归。
- 修复：任何含 `builtin.target.os` / `std.os.windows` / `std.posix` / comptime 平台分支的 `*.zig` 改动一律视为需要 macOS，或基于 AST 证明 `else` 未变。

### 5.7 P1：无 Windows CI job

- 证据：`build.zig:100,106,123,162,164` 在 Windows 跳过 POSIX suites；`ci.yml` 只 Linux x86_64 + 条件 macOS；`binary-size.yml` 无 Windows 矩阵。
- 后果：`zig build test` 在 Windows 近乎空 step 却返回成功，§5.2–5.6 全部无法由 CI 捕获。
- 修复：加 Windows job 跑 `zig build` + `zig build test` + smoke；跳过 suites 时显式输出而不要 silent green。

### 5.8 P3：Windows 本地时间静默回退 UTC

`src/core/shared/local_time.zig:128-159`，见 §5.1。非崩溃，仅时区显示差异。

### 5.9 该域已确认合规

发布目标矩阵在 `binary-size.yml`、`dev-release.yml`、`release.yml`、`cdn-backfill.yml`、`ci.yml`、`publish-libfx.yml`、`scripts/pgso/platforms.py` 中一致为 Linux x86_64/aarch64 + macOS x86_64/aarch64；`build.zig` 通过 `standardTargetOptions` 支持显式 `-Dtarget`，原生 Windows 默认改 MSVC ABI。

## 6. 审查方法记录：一次假阳性撤回

保留此节是为了让后续修复者知道哪些结论被实机反证过，避免重复劳动。

1. `portability-review-2` 初版按「comptime 返回只影响运行时路径，函数体后续分支仍参与类型检查」的假设，判定 5 个模块的 `std.posix.poll` / `termios` 会让 Windows 编译失败（P0）。
2. 主代理执行 `zig build`：编译链接无错，仅 install 因 `fx.exe` 被占用而 `AccessDenied`。同时 `zig-out/bin/fx.exe` 正在运行，构成直接反证。
3. 主代理把结果反馈给该代理；它复核 Zig 0.17 的惰性分析与 comptime 裁剪，撤回 5 条 P0 与 1 条 P1，合并 1 条、降 1 条为 P3、新增 1 条（§5.2），最终 7 条。
4. 教训：静态审查对「平台条件编译 + 惰性分析」容易过度判定；涉及编译失败的结论必须用目标平台实机构建裁决。

## 7. Shell 选择与子代理工具上下文（最高价值）

来源：`shell-chain-review`，31 个文件，4 条定向结论（累计 10 条）。主代理另自行复核 `src/builtins/tools.zig:76-125`。本域解释了本轮两个子代理为何整轮报废。

### 7.1 根因：工具描述里的示例本身就是错的

- `src/builtins/tools.zig:80-81` 的 Windows 说明写：`Pass shell={"kind":"bash"} for Git Bash.`
- `src/builtins/tools.zig:97-105` 的 `shell_executable_schema` 却只接受 `kind` 枚举 `"executable"`，`required = { "kind", "path" }`，`additional_properties = false`。
- `src/builtins/tools.zig:118` 还把 `shell` 字段标注为 `For run with tty=true`；`src/tools/shell/shell.zig:445-448` 对非 tty 路径会拒绝它并要求 saved session。
- 即描述同时违反**参数形状**和**适用条件**。正确形状应为 `{"kind":"executable","path":"bash"}`（且需 tty/saved session 语境）。

### 7.2 传播链：错误示例 → 参数校验失败 → 误判重复 → 整轮终止

| 环节 | 位置 | 行为 |
| --- | --- | --- |
| 描述定义 | `builtins/tools.zig:80-95`、`:425-435` | `description` 与 `model_schema.description` 都设为含错误示例的文本；comptime 断言不超 2048 字节 |
| 子代理是否收到 | `core/cli/cli_ask.zig:270-287`、`core/app/app_agent_runtime.zig:1216-1227`、`core/modes/mode_registry.zig:43-55`、`core/tooling/tool_projection.zig:566-577`、`core/subagent/agent_adapter.zig:445-464`、`:310-319`、`core/agent/runtime/orchestrator.zig:7584-7593`、`gateway/chat_completions_protocol.zig:107-119`、`gateway/anthropic_messages.zig:113-124` | **子代理能收到完整描述，没有被裁剪或替换**；此前「描述被裁剪」的假设已排除 |
| 参数校验失败 | `tools/shell/shell.zig:185-190` → `:302-453` → `:455-468` | 产出 `{"error":{"code":"invalid_shell_request","executed":false,"problems":[...],"instruction":"Call shell once using retry_with exactly.","retry_with":...}}`；连续两次用 `{"kind":"bash"}` 都会得到 `shell must be an object matching its schema.`、`repairable=false`、`retry_with=null`，输出全文完全一致 |
| 判重 | `core/tooling/tool_result_errors.zig:107-142`、`core/agent/runtime/tool_admission.zig:205-235` | `observe` 只认 `code=invalid_shell_request && executed=false`，然后**对 `model_output` 全文做 SHA-256**，不哈希 `call.arguments_json`，也不判断模型是否按 `retry_with` 改过参数 |
| 终止 | `tool_admission.zig:178-187`、`:225-235`；`orchestrator.zig:9799-9800`、`:12007-12027`、`:12226-12279` | 第一批进 `previous`，第二批命中即 `stop_after_batch=true` → `finishFailedTurnWithNotice` → `.failed` 结束整个 turn，`notice` 作为 assistant 文本落 history，之后 `return`，无 `appendContinuationPrompt` |

### 7.3 P1：判重 digest 语义错误

两次不同 `command`、不同 `shell` 尝试，只要产生同一句 problem 文本且 `retry_with` 同样为 `null`，digest 就相同。典型场景：连续两次按描述写 `shell={"kind":"bash"}`。`shell.zig:2243-2253` 的测试还证明不同成员顺序会规范化成完全相同的 correction 字符串。

- 修复：`tool_admission.zig:205-235` 改用规范化调用指纹，包含 `call.arguments_json`、problem 类别、是否 materially changed command/shell；按错误语义分类而非全文 digest。

### 7.4 P1：2 个 batch 即终止，对未执行、无副作用的探索过严

- 对比：malformed arguments 是 3 个连续全坏批次（`tool_admission.zig:36`、`:397-408`）；执行失败是同一参数连续 3 个未改文件步骤（`:238-243`、`:291-305`）。terminal validation 只有 2 batch，且惩罚的是**未执行、无副作用**的调用。
- 边界：命令字符串内部的 pwsh 引号错误**不会**触发这条 guard（`shell.zig:472-487`、`:606-626` 不解析命令语法），会真实执行后归入 `ShellExecutionFailureRetryState`；触发本 guard 的是 JSON 参数/字段形状错误。
- 实证：`session-review`、`portability-review` 两个只读审查子代理整轮报废。
- 修复：对 validation-only 失败提高预算、区分「未执行」与「已执行失败」，或只读子代理不终止整轮；至少保留一次 continuation。

### 7.5 P1：终止 notice 完全不可操作

- `orchestrator.zig:155-156` 的 `repeated_terminal_validation_notice` = `Repeated shell validation failures stopped the tool loop. The invalid shell calls were not executed and produced no shell effect.`
- 不含 `pwsh`、`bash`、`Git Bash`、`executable`、`path`、`retry_with`，也无 continuation；对比 `:159-160` 的 malformed notice 尚且写 `Continue with a follow-up prompt if needed.`
- 单次 tool result 里其实有 `retry_with` 与 `instruction`，第二次相同调用还会由 `tool_batch.zig:82-93` 追加 `Do not retry it unchanged.`（`tool_admission.zig:370-378`），但终止 notice 把这些全丢了。
- E2E 只断言这句泛化文本：`tests/e2e/gateway-stream-lifecycle.test.ts:5049-5055`。
- 修复：notice 附最后一次 `problems`/`retry_with`、正确形状 `{"kind":"executable","path":"bash"|"pwsh"}`、当前平台可用 shell，并追加自我纠正 prompt。

### 7.6 排除项：子代理描述未被裁剪

`builtins/tools.zig:747-770`（生产 registry 含 shell）、`:772-784`（`names_only` 只用于 N-API/libfx addon，注释明说 addon 只跑 host 工具）、`:864-868`、`main.zig:1943-1965`、`core/hosts/runtime_profile.zig:33-46`、`builtins/tools.zig:458-470`（headless `fx ask` 根运行换 process-only spec，但 `cli_ask.zig:278-287` 的 `runAskChild` 用 `ctx.deps.tool_set` 重新投影，子代理拿完整 `model_schema`）。四个 `core/subagent/*` 文件都不做 spec 拼接（`tool_host.zig:3012-3048`、`authority.zig:45-49`、`tool_provider.zig:20-46`、`model_contract.zig:107-120`）。

平台上下文只补 `operating_system` 与默认 `shell_path`（`builtins/context.zig:2599-2609`、`:3516-3531`、`agent_adapter.zig:723-731`），没有 Git Bash 可用路径或合法 `shell` 参数形状，无法纠正错误描述。

### 7.7 最小修复顺序

1. 同步修正 `builtins/tools.zig:81` 的描述与 `:97-105` 的 schema，补 child projection 一致性回归测试。
2. 收窄 `TerminalValidationRetryState.observe` 的归类与 digest。
3. 把终止 notice 改成可执行恢复提示并保留一次 continuation。
4. 补 E2E：Windows 上按描述切 Git Bash 不应导致整轮失败。

## 8. 多子代理并发内存（实测）

来源：`runtime-mem-review`，64 个文件，15 条发现。用户实测反馈：开了很多子代理后后台看到 fx 内存 670+ MB；主代理随后做了三次采样。

### 8.1 实测数据

主 fx 进程 PID 49308（同时跑 12+ 个子代理）：

| 采样 | WS | Private/Paged | Virtual | Handles | Threads |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 1535.4 MB | 6915.5 MB | 11140.8 MB | 781 | 312 |
| 2（+2s） | 1548.1 MB | 6824.1 MB | 11046.2 MB | 775 | 306 |
| 3（+4s） | 1561.7 MB | 6928.0 MB | 11150.2 MB | 777 | 308 |

另有约 10 个 `pwsh` 子进程合计约 1 GB WS，属其他进程不计入 fx 本体。用户看到的 670 MB 大概率是较早时刻、不同计数器面板或「私有工作集」读数。

Private 在 4 秒内先降 91 MB 再升 104 MB，线程数 306–312 波动，WS 只升约 26 MB —— **不是单调泄漏曲线**。

### 8.2 结论：随并发线性增长的合理占用 + 线程栈放大，静态未发现明确真实泄漏

`Private ≈ 6.8 GB` 而 `WS ≈ 1.5 GB` 是「高提交、低驻留」：

1. Windows 的 Private Bytes / `PagedMemorySize64` 近似私有提交量，Working Set 是当前驻留物理页；提交不等于已触碰或泄漏。
2. Zig 0.17 `std.Thread.spawn(.{})` 默认 `stack_size = 16 MiB`；Windows 实现把该值传给 `NtCreateThreadEx` 的 `StackCommit`。线程实际只触碰少量栈页，其余可不进 WS。
3. `src/main.zig:4126-4131` 设 `async_limit = .unlimited`；`std.Io.Threaded` 默认 `concurrent_limit = .unlimited`；工作线程按需增长且永久入池。308 × 16 MiB ≈ 4.8 GiB（约 5.1 GB）栈相关提交/保留，与 6.8 GB Private、11 GB Virtual 量级吻合。
4. `build.zig:77` `link_libc = true`，`src/main.zig:4232-4234` 用 `c_allocator`；CRT/Windows 堆可能保留已提交但已释放区域，形成「逻辑已 free、提交仍高、WS 不高」。
5. 若采样里的 Paged 实为内核 paged pool 而非进程私有提交，需用 VMMap/PoolMon 区分；但 Private 与 Paged 数值相同，更像 .NET `Process` 的私有/可分页内存列。

**300+ 线程不符合 12 个子代理的最小必要并发**：12 slot + 12 agent worker 只是基线，放大来自无上限 Io 线程池、每个并行工具调用一条线程、若干后台线程。

### 8.3 量化归因

| 项 | 量级 | 依据 |
| --- | ---: | --- |
| 线程栈提交/保留 | 约 4.8–4.9 GiB | `$STD/Thread.zig:303,307,560-601`、`$STD/os/windows/ntdll.zig:808-813`、`src/main.zig:4126-4131`；代码 + Windows 提交语义 |
| 线程放大来源 | 12 slot + 12 worker 基线，再增数百 | `managed_owner.zig:273`、`app_agents_runtime.zig:1643-1649`、`parallel_execution.zig:230-243`、`$STD/Io/Threaded.zig:2097-2117` |
| CRT/堆高水位 | 数百 MB 到 1–2 GB | `build.zig:77`、`main.zig:4232-4234`、`orchestrator.zig:5719-5721`；部分为推测 |
| 子代理上下文/历史/请求体 | 约 10–100 MB | `agent_adapter.zig:223-283,296-340`、`agents/agent.zig:21`、`tool_result_limits.zig:7` |
| 工具结果/报告临时副本 | 每报告 2–5 份、默认每份 ≤64 KiB，12 份约数 MB 峰值 | `reports.zig:166-203`、`app_agents_runtime.zig:202-240,1475-1492`、`main.zig:2144-2146` |
| MCP view / tool schema / skill catalog | MB 级或更低 | `domain.zig:146-171`、`authority.zig:81-113`、`agent_adapter.zig:739-777` |
| registry / debug trace / tape | registry ≤512 KiB、trace ring 64 条、debug 单行 64 KiB | `child_state.zig:19-20`、`compactor/trace.zig:43-44`、`debug_trace.zig:15-16`、`record_tape.zig:124-160` |
| 真实泄漏 | 静态未发现足以解释 GB 级的候选 | `errdefer`/`deinit` 覆盖、`finishWithReport` 清 active、`ReportPost.destroy`、采样非单调 |

### 8.4 复杂度回答

设 `N` 并发子代理数、`C` 父传根上下文长度、`H` 子自身历史、`R` 结果/报告上限、`T(N)` 实际线程数、`S=16 MiB`：

```
Peak ≈ O(T(N) * S) + O(N * (C + H + R + tool_specs + report_copies)) + O(1)
```

**当前实现是 `O(N*上下文长度)`**；当 `C/H/R` 被现有上限固定时观测上退化为 `O(N)`，绝不是 `O(1)`。主导项是 `T(N)*16 MiB`，不是上下文复制。只有共享不可变上下文 + 固定大小线程池 + 按子代理回收空闲 worker 才能变成 `O(1) + O(min(N, concurrency_cap))`。

### 8.5 P0 三项（唯一有望直接消除 6.8 GB 提交的改动）

1. `src/main.zig:4126-4131` + `$STD/Thread.zig` + `$STD/Io/Threaded.zig`：`async_limit=.unlimited`、`concurrent_limit=.unlimited`、`std.Thread.spawn(.{})` 默认 16 MiB 栈。→ 统一 `spawnWithSmallStack`，显式 `.stack_size = 1–4 MiB`，`processIoOptions` 同样设置；`async_limit`/`concurrent_limit` 设为 CPU 数或固定上限。`std.Io.Threaded` 达上限时已定义同步执行 / `ConcurrencyUnavailable` 语义，不改变任务结果，只改调度位置。仅把 16 MiB 降到 2 MiB，按 300 线程估算约减少 4.1 GiB 提交。
2. `src/core/subagent/managed_owner.zig:232-275` + `child_state.zig:20` + `tool_host.zig:1509` + `agent_frame.zig:15`：`max_children=256` 是注册表容量不是同时运行上限；每个 admitted work 立即 `std.Thread.spawn` 起 slot，无背压；`queue_cap=64` 的报告队列不构成运行数背压。→ 在 `Owner.start` 前加 `max_running_children` 许可门，超出时把 `ActiveWork` 留在 pending/registry 队列，按 `work_id`/fingerprint/创建顺序启动；取消时只写标记不启动线程。
3. `src/core/agent/runtime/parallel_execution.zig:207-216,230-243,272-280`：每个并行工具调用再起一条 16 MiB 栈线程 + 一个 arena；12 个子代理各 20 个工具调用即可新增约 240 条线程。→ 用 bounded shared worker pool，多余 call 排队；`attempts[index]` 仍按原 index 写回，保留 `completion_state` 与 `first_cancelled_index` 语义。

### 8.6 P1 主要项

- `agent_adapter.zig:223-247,277-283,333-335` + `tool_host.zig:2828-2840` + `child_state.zig:86-134`：`root_user_messages`、`root_user_intent_context`、instructions、系统 prompt、子历史按子代理/按 work 复制，形成 `O(N*C)`。`root_user_intent_context` 有 1024 B 上限，但 `root_user_messages` 列表在 subagent 目录未见条数/总字节上限。→ 不可变引用计数 / COW slice，mutation 时才复制；保持各 child 独立 `work_id`、root authority、compaction state、live authority generation。
- `agent_adapter.zig:149-151` + `orchestrator.zig:5719-5721,5753-5754,5787-5788,7144-7145`：**不是**整个父 turn 共用一个大 arena；每个 child run / model turn 各有 arena，overlay arena 每 step `reset(.retain_capacity)`。但 `within_turn_suffix` 的工具结果活到 turn 结束，N 个并发 turn 同时持有各自峰值。→ 大工具结果转成 `result_store` handle 后尽早释放，移到 step-scoped arena 或持久文件；保留 `buildExecutionMemory` / `persistCancelledTurn` 的只读投影。
- `gateway/chat_completions.zig:112-157`、`anthropic_messages.zig:86-92,155-163`：每子代理每 model step 都把投影消息、instructions、tool schema JSON、完整 request body 序列化到独立分配。→ interned immutable JSON、request body 流式写 HTTP writer、per-child scratch buffer；不改变 provider 看到的字节。
- `tool_result_limits.zig:44-68`、`execution_memory.zig:951-974`、`session/result_store.zig:109-140`：`safe_output` 只是别名不是额外拷贝，但 raw / sanitized / capped / durable full output 可有 2–4 份瞬时副本。→ borrowed fast path、先按 cap 取 prefix 再 sanitize、durable full output 流式写文件；保留 `output_bytes`/`stored_output_bytes`/`truncated`/`preview`/`output_handle`。
- `max_tool_result_bytes`（默认 64 KiB）在子代理内部工具结果、父收到 report/message、通用 `subagent` tool context 三条链路均生效；但 `formatFailedResult`/`withPartial` 可能先拼出较长 partial 再截断。→ 在源端传入 cap。
- `app_agents_runtime.zig:57-112,1643-1665,2105-2111` + `agents/child_run.zig:83-95`：finished 子代理的 slot 可回收，但 `ChildAgent`、screen transcript、pacer、session runtime、worker thread 可能保留到 app/close，形成 `O(N)` 常驻基线。→ 报告已投递且 session 已 commit 后设 idle timeout，只保留 durable child id/name/instructions/admission 元数据。

### 8.7 P2 / P3

- P2：`domain.zig:61-78,146-171` + `authority.zig:81-113` + `mcp/access_policy.zig:71-76`：MCP capabilities/view、系统 prompt 按 admission/run 复制；tool schema 与 skill catalog 未见每子代理重载，`grep indexer` 在 subagent 目录无命中。→ 按 `authority_generation` 版本化的 `Arc`/COW。
- P2：`managed_owner.zig:497-559` + `child_state.zig:19-20,362-369,575-593`：`observe`/`phaseTransition`/`finish` 反复 `load` 并 `clone` 整个 registry，`appendChild` 每次 `alloc(len+1)` + `@memcpy`；受 512 KiB / 256 children 上限约束，不解释 GB 级常驻。→ 进程内单一 authoritative registry + mutex 增量 mutation，持久化仍追加 `child_spawned/finished/taken` 行。
- P2：`link_libc` + `c_allocator` + `deinit_arena` 只 `arena.deinit()`：CRT 可能保留已提交区域，形成堆高水位。→ 降低峰值分配、缩短大 buffer 生命周期；不要用 `EmptyWorkingSet` 伪装降低 WS。
- P3（排除项）：`errdefer`/`deinit` 覆盖 admission clone 与 ActiveWork；`finishWithReport` 清 `active`；`destroySlot` join 后释放；`ReportPost.destroy`、`deliverReports` 清空队列；所有 run/turn arena 有 `defer deinit_arena`。静态结论「合理增长无明显泄漏」，但需所有子代理结束后连续采样 60 秒 + VMMap/UMDH + `FailingAllocator` 错误路径 sweep 才能最终确认。
- P3：debug trace / tape / compactor trace / session picker / approval / feedback 队列均有界（2 MiB 日志、64 KiB 单行、64 条 ring、64 队列），不能解释 6.8 GB。

### 8.8 落地优先级

1. **P0**：统一小栈 `std.Thread.spawn` + `processIoOptions.stack_size`；`async_limit`/`concurrent_limit`/并行工具线程/活跃子代理数设为有界。仅 16 MiB → 2 MiB 按 300 线程估算约减少 4.1 GiB 提交。
2. **P1**：共享不可变 root context / system prompt / MCP view / tool schema；报告 buffer 单所有权转移；源端应用 `max_tool_result_bytes`；finished child 的 worker/screen 回收。
3. **P2/P3**：registry 增量更新、debug/tape 显式配额、完成后 heap snapshot 与 failing allocator 回归。

所有建议保持现有正确性边界：同一 child 串行、不同 child 并行、报告按 `child_finished/taken` 顺序投递、`work_id`/fingerprint 去重、live authority generation、compaction/finalization 可见消息、truncation marker 与 result handle 语义。

### 8.9 建议的验证方式

- VMMap 按 `Stack` / `Private Data` / `Heap` / `Mapped File` 分类看 12 child 运行中、全部 finished 后、退出前三个点。
- 对 1 / 8 / 12 / 24 个子代理记录 `PrivateMemorySize64`、`WorkingSet64`、`Threads`，预期栈提交从约 16 MiB/线程降到目标值，Threads 在 cap 后平台化。
- 所有 child finish 后连续采样 60 秒，若 Private/Virtual/Threads 长期不回落才优先怀疑 CRT 堆保留提交或 detached thread。

### 8.10 重要修正与待实测项（主代理复核后追加）

审查期间主代理对 §8 的两处表述做了核实，必须修正，避免后续按错误前提优化：

**修正 1：线程数不等于代理数，且我先前少报了代理总数。** 最初主代理按工具里的 `subagent status` 报「17 个子代理」，但该列表**只含主代理的直接子**，看不到孙代理。改从磁盘核实后修正如下：

- `.fx/sessions/v2/index.jsonl` 记录真实层级：顶层会话 `pSdbC3jO7tQ_`（主会话）；`parent` 指向它的有一级子代理；而 `_JqMKB3vMpRJ` 的 `parent` 是 `D-Oh2sdZ-KLB`（本身是一级子代理），即**存在三级结构：主代理 → 子代理 → 子代理的子代理**。
- `v2` 下共 **223 个会话目录**，其中 **158 个在 2026-11-06 当天创建或更新**，绝大部分由本轮递归审查产生。
- 因此「代理数量」应以会话目录/`index.jsonl` 为准，不能以 `subagent status` 的可见列表为准；后者天然低估。

308 条线程来自「每代理约 2 条基线线程 + 每个并行工具调用 1 条线程 + 无上限 `std.Io.Threaded` 池 + 后台线程」，遍布 223 个会话继承的运行时，而不是 308 个代理。证据：`src/core/agent/runtime/parallel_execution.zig:230-243`、`src/main.zig:4126-4131`。

**这项修正直接强化了 §8.5 第 2 项与 §10 的必要性**：既然单进程能递归产生 223 个会话、线程涨到 300+，只靠「用户手动少开几个」不可控，必须有代码层的深度与并发上限。

**修正 2：16 MiB 是栈大小提示，不是保证的提交量。** `$STD/Thread.zig:307` 的 `default_stack_size = 16 * 1024 * 1024` 与 `:560` 的 `const stack_size = @max(64 * 1024, lossyCast(u32, config.stack_size))` 确实把该值传给 `NtCreateThreadEx` 的 `StackCommit`（`$STD/os/windows/ntdll.zig:812`），但 `$STD/Thread.zig:557-559` 的注释明确写着：Windows 只保证 AllocationGranularity 粒度的最小栈，更小的值会回落到 exe 默认（约 1 MB），**且 「stack size is only a hint」**。

因此 §8.2 里「308 × 16 MiB ≈ 4.8 GiB」只能作为**上界估算**，不能作为已证实的归因。6.8 GB Private 中栈、CRT 堆保留、文件映射各占多少，必须实测区分。

**已确认的事实**（可据此行动）：

- 实测线程数峰值 312，全部代理停止后仍有 175~195 条，说明线程不随代理结束回收而留在线程池。
- `src/main.zig:4126-4131` 的 `async_limit = .unlimited` 与 `std.Io.Threaded` 默认 `concurrent_limit = .unlimited` 是线程数无上限的直接原因。
- 每个并行工具调用单独 `std.Thread.spawn`（`parallel_execution.zig:230-243`）。
- `max_children = 256`（`child_state.zig:20`）是注册表容量，不是并发上限；`Owner.start` 前无许可门（`managed_owner.zig:232-275`）。

**未确认、需要实测的项目**：

| 待测项 | 方法 | 判定标准 |
| --- | --- | --- |
| 栈提交真实占比 | VMMap 按 `Stack` / `Private Data` / `Heap` / `Mapped File` 分类，对比运行中与停止后 | 若 Stack 远低于 4.8 GiB，则 §8.5 第 1 项的收益估算需相应下调 |
| 线程池是否真的不回收 | 停止全部代理后连续 60 秒采样 `Threads` | 若长期停在 175+ 且不再下降，确认池不回收 |
| CRT 堆高水位 | 同上三个时点的 `Heap` 分类 | 若 Heap 提交不降而 live 对象已释放，确认是高水位而非泄漏 |
| 6.8 GB 的构成 | 上述三项合并 | 只有在实测后才可写入修复收益预期 |

### 8.11 空闲不退内存的实测（2026-11-06 14:00，全部代理停止后）

用户关键观察：代理全部关掉后，进程仍占约 3.6 GB。主代理实测确认，并新增了「CPU 长期占用」这一独立问题。

**空闲 20 秒采样（全部子代理已停止，PID 49308）**：

| 指标 | 采样 A | 采样 B（+20s） | 变化 |
| --- | ---: | ---: | --- |
| Working Set | 3758 MB | 3758 MB | 0 |
| Private | 11598 MB | 11598 MB | 0 |
| Threads | 169 | 169 | 0 |
| CPU 增量 | — | — | **0 秒（0% of one core）** |

**判定：静止占用，不是持续泄漏。** 真泄漏会让 Private 持续单调上升；这里完全冻结。所以性质是「已用过的内存不归还」，不是「一直在漏」。

**进程生命周期数据**：11:46:38 启动，至 14:00:42 运行 134.2 分钟，累计 CPU 129.6 分钟，**平均 0.97 核**（16 逻辑核）。CPU 最高的单线程 60620 累计 12.3 分钟，硬件采样间隔内是 `ExecutionDelay`。

**三层可能原因（按可信度排序，均未实测定论）**：

1. **`c_allocator`（CRT 堆）高水位** —— 可信度较高。`build.zig:77` 开 `link_libc`，`src/main.zig:4232-4234` 用 `c_allocator`；Windows CRT 释放后通常保留已提交区域不 decommit，表现为「逻辑 free、私有提交不回降」。
2. **线程池不回收** —— 可信度高（已有实测支撑）。`async_limit = .unlimited` + `std.Io.Threaded` 默认 `concurrent_limit = .unlimited`，169 条线程永久留池，每条线程的栈提交随之锁住。停止全部代理后线程仅从 308 降到 169，不再下降。
3. **223 个会话的 arena 仍被引用** —— 未证实。若父对象仍持有已结束子代理的 arena 或注册表，`arena.deinit()` 不会触发。**仅凭进程计数无法区分此项与第 1 项**，需要 VMMap 分类或给 fx 增加内存统计出口。

**新增独立问题：空闲期之前的 CPU 占用偏高。** 134 分钟内烧掉 129.6 分钟 CPU，对一个「开代理、等结果」的交互式会话偏高，需单独排查是否为轮询/自旋。注意：空闲 20 秒实测 CPU 增量为 0，说明**空闲时不自旋**，问题出在**活跃期**，不能与「空闲占内存」混为一谈。

**验证方法**（必须按顺序，否则会误判）：

1. `VMMap` 或 `procdump` + 分类视图，看 `Heap` / `Stack` / `Mapped File` / `Private Data` 各占多少，三个时点：全部代理运行中、全部停止后 1 分钟、停止后 10 分钟。
2. 若 `Heap` 提交不降而 live 对象已释放 → 确认第 1 项（CRT 高水位），修复方向是降低峰值分配，不是加 `EmptyWorkingSet`。
3. 若 `Stack` 占比大且线程数不降 → 确认第 2 项，修复方向是给线程池设有界并发与小栈。
4. 第 3 项只有在 1、2 都排除后才值得投入，方法是给会话/arena 增加释放计数并暴露到 `/status` 或 debug trace。

**结论不变的部分**：`async_limit = .unlimited`、并行工具逐条起线程、子代理无并发上限，这三项无论栈大小如何都应当收敛为有界值；它们是可控性问题，不是纯内存问题。修复它们的理由不需要依赖 16 MiB 这个数字成立。

## 9. 会话、配置与持久化

来源：`session-review-2`，9 条发现（3 P1 / 5 P2 / 1 P3）。严格只读、未调用 shell、未运行构建/测试/二进制，全部为**静态代码证据**，置信度见各条。已核对 65 个范围内文件 + 追溯调用链的 76 个相关文件 + `tests/tla/session_manager/` 的 TLA+ 模型与设计记录。

### 9.1 P1：Windows 上 v2 会话目录发布可能丢弃已发布会话

- 证据：`src/core/session_manager/storage.zig:354`（注释自述「文件夹 rename 永不替换非空文件夹，返回 AlreadyExists」）、`src/core/session_manager/session.zig:774-775`（`rename(tmp, id, root, id)`）、`:634-639`（`makeDir(.tmp/{id})` 遇 `AlreadyExists` 就 `deleteTree` 再重建）。
- 触发：Windows 上两个进程以同一显式 ID 发布/导入会话，都通过「ID 尚不存在」检查并在 `.tmp/{id}` 暂存；一个删除并重建同名暂存目录时会删掉另一个正在发布的暂存目录；最终目录 rename 又可能覆盖或拒绝替换。
- 后果：已发布会话的 `log.jsonl`、`lock`、`blobs` 丢失或与另一会话混合，恢复/列表/子会话关系损坏。随机 ID 冲突概率低，但显式 ID 的 v1 转换、salvage、fork 路径可触发。
- 置信度：中。修复：每 ID 锁或全局发布锁；以 `mkdir(exclusive)` 成功者为唯一发布者；禁止无条件 `deleteTree(.tmp/{id})`；发布前再 `stat` 最终目录并原子占名。扩展 `Lifecycle.tla`/`Wiring.tla` 覆盖双进程同 ID 发布。

### 9.2 P1：v2 恢复重建 `DurableSessionState` 时丢失 `origin_workspace_root`

- 证据：`src/core/session/session_adapter.zig:2743-2746`（`durableState()` 调 `resumedOf(alloc, &restored, self.id(), workspace)`）、`:4489-4500`（`origin = dupe(workspace)`、`workspace_copy = dupe(workspace)`，两者同源）、`src/core/output/output_contracts.zig:1643-1647` 把 `origin_workspace_root` 输出为 JSON；v1 codec `session_codec.zig:1512-1516` 则分别读取两个字段。
- 触发：会话在 `/w1` 创建、在 `/w2` 恢复。v2 workspace repair 记录了当前 workspace，但 `durableState()` 把 origin 和 current 都设为 `/w2`。
- 后果：跨 workspace 恢复后持久化状态/快照/结构化输出无法再区分原始 workspace，`origin_workspace_root` 语义退化；与 `AGENTS.md:162`「current 更新」只部分一致。
- 置信度：高。修复：v2 日志分别持久化 `session_created.workspace` 与当前 `set workspace`，或新增 origin 字段；`resumedOf` 接受两个独立参数；补跨 workspace resume 的序列化/JSON 回归测试。

### 9.3 P1：v2 导入 staging 的 TOCTOU 可删除另一个进程的暂存数据

- 证据：`src/core/session_manager/api.zig:353,358-368`（`openImport` 只 `stat` 最终目录与 tombstone，不占有跨进程 staging 名称）、`session.zig:634-639` 的 `deleteTree(.tmp/{id})`。
- 触发：两个进程同时导入同一个 v1 ID，两者都看到 `.tmp/{id}`，其中一个删除另一个的目录。与 §9.1 同源但发生在更早的 staging 阶段，**不需要随机 ID 碰撞**。
- 后果：转换中的事件/blobs 被删或覆盖，可能发布不完整会话。
- 置信度：高。修复：独占创建 `.tmp/{id}.claim` 或每 ID 锁文件，锁生命周期覆盖 `openImport` → `publishImport`；清理只针对自己持有 claim 的目录。

### 9.4 P2：配置加载器与 `AGENTS.md` 的环境变量优先级不一致

- 证据：`src/core/config/config_runtime.zig:1256,1268-1277`（`loadMergedSettings` 合并文件与 workspace override 后只调 `resolve_provider_selection`，后者只应用 `FX_PROVIDER`；不调 `applyEnvSettingOverrides`）、`src/core/app/app_session_runtime.zig:4839-4841`、`src/acp/server.zig:3646-3651` 直接使用简化加载器结果。
- 触发：长生命周期进程在 `FX_PROVIDER_ORDER`、`FX_PROVIDER_STRICT`、`FX_REVIEW_MODEL`、`FX_THEME` 存在时通过上述简化加载器重读配置、恢复会话、切换 provider 或处理 ACP 模型选择；启动时的 `loadMergedSettingsDetailed` 应用过 env 覆盖，但这些返回值里没有。
- 后果：同一进程内不同路径看到不同配置；`fx config list` 显示 env 生效而部分运行时仍用文件/默认值；`provider_strict`/`provider_order` 可能改变请求路由，`review_model` 可能改变自动权限审查模型。与 `AGENTS.md:151-158` 优先级 2 冲突。
- 置信度：高。修复：把所有 `FX_*` 解析集中到 `Settings` 构造/合并函数，保证 detailed / fast / 简化路径同一结果；或明确禁止简化加载器参与运行时决策；补 env-vs-file 优先级测试。

### 9.5 P2：命令行 `--config` 被环境变量无条件压过

- 证据：`config_runtime.zig:1411-1418,1472-1476`（`applySettingOverrides` 注释明说「像 git 的 GIT_* 变量压过 -c，`FX_*` override 仍胜出」，并在 merge 后**再次**跑 `applyEnvSettingOverrides`）、`src/core/app/app_lifecycle.zig:794`、`config_runtime.zig:3053-3062` 的测试明确断言环境变量胜出。
- 触发：`fx ask --config provider_strict=true ...` 同时环境带 `FX_PROVIDER_STRICT=0`。
- 后果：`--config` 是 `fx ask` 的命令行机制，`AGENTS.md:153-154` 规定命令行标志优先于环境变量；当前把一部分环境变量反置于 `--config` 之上，显式单次运行参数被静默忽略。
- 置信度：高。修复：区分「命令行 flag」与「环境变量」；`settings_overrides` 来自 CLI 时最后应用，或让 `applyEnvSettingOverrides` 先执行、`--config` 后执行；仅对文档明示的进程级变量保留例外，同步更新 AGENTS.md、帮助文本与测试。

### 9.6 P2：环境变量布尔值与数值解析口径分叉

- 证据：`config_runtime.zig:759-764` 的 `parseEnvBool` 接受 `1/true/on/yes` 与 `0/false/off/no`；`src/core/config/env_settings.zig:49-51` 的 `autoUpgradeOff` 只认 `0`/`false` 且不 trim；`config_runtime.zig:314-317` 的 `providerEnvOverride` 返回未 trim 的原串；`src/wasm_core_main.zig:176-178` 又规定 `FX_FAST`/`FX_ULTRAFAST` 只接受 `true/1`/`false/0`。
- 触发：`FX_AUTO_UPGRADE=off|no|"FALSE "`、或 `FX_PROVIDER=" gateway "`（带空格导致 `model_provider.parse` 失败）。
- 后果：环境变量有时被忽略、有时导致启动错误、有时 native 与 wasm 行为不同；`fx config list`、doctor、实际启动可能对同一变量得出不同结论。
- 修复：定义单一 `parseEnvBool(trimmed)` 与 `trimmedEnv()`，所有 `FX_*` 读取统一调用；统一词表；对每个变量非法值明确选「忽略并诊断」或「拒绝启动」；补跨平台表驱动测试。

### 9.7 P2：Windows workspace 路径规范化只处理 `/` 不处理 `\`

- 证据：`src/core/session/session_store_paths.zig:30-38`、`config_runtime.zig:2199-2205` 都只 `while (end > 1 and workspace_root[end-1] == '/')`；`src/core/session/session_store.zig:200` 用其哈希作为 remembered-session 文件名、`:918-950` 保存 `workspace_root`；过滤用 `std.mem.eql` 字节比较（`session_summary_codec.zig:55-57`）。
- 触发：Windows 上同一目录以 `D:\repo` 与 `D:\repo\` 传入，或盘符大小写/分隔符混用。
- 后果：`~/.fx/settings.json` 的 `workspaces["<path>"]`、remembered-session 文件、当前 workspace 过滤会对同一目录产生不同键；`fx -c` 可能找不到上次会话，workspace override 不生效，列表错误排除会话。
- 置信度：高。修复：所有持久化/比较键用 `realpathAlloc` 或平台感知规范化；Windows 同时处理 `\`、盘符大小写、UNC/扩展路径；补同一目录不同拼写形式的测试。

### 9.8 P2：自动升级在 Windows 上依赖 Unix 风格 `TMPDIR` / `tar`

- 证据：`src/core/upgrade/auto_upgrade.zig:288-293`（`getenv("TMPDIR") orelse "/tmp"`，用 `"{s}/"` 拼接）、`upgrade_helpers.zig:378-381` 调外部 `tar -xzf`、`src/core/shared/io.zig:877-879`（Windows `syncVerifiedDir` 直接 `error.OperationUnsupported`）。
- 触发：Windows 原生环境未设 `TMPDIR`，自动升级进入下载/解压/替换阶段。`/tmp` 不是有效 Windows 绝对路径，`sweepStaleDownloadDirs` 的 `isAbsolute` 检查会跳过清理；外部 `tar` 未必存在。
- 后果：自动升级失败或残留下载目录；`copyFileAtomic` 虽做文件 sync 但无法同步目录改名，崩溃后安装落地状态不如 POSIX 明确。
- 置信度：中高。修复：用平台临时目录 API 读 `TMP`/`TEMP` 并 `std.Io.Dir.path.join`；Windows 用内置解压或明确禁用自动升级；为目录同步失败定义显式 recovery 并记录安装结果。

### 9.9 P3：时间戳窗口与持久化状态校验边界不一致

- 证据：`src/core/auth/auth_runtime.zig:194-217`（`milliTimestamp()` 截成 `u32`，约 49.7 天回绕；`noteRequestPathCredentialVerified` 分两次原子写 source 与 timestamp）、`session_codec.zig:402`、`:1069`、`session_catalog.zig:115-116`（`i64` 直接相减未用饱和减法）。
- 后果：凭据刷新「最近验证」窗口可能短暂误判（注释说明只多一次未授权重试，影响有限）；会话状态/目录缓存对倒退时间或极端时间校验不一致，可能溢出、错误排序或把合法旧状态判无效。未发现凭据或会话内容泄露路径。
- 置信度：中。修复：用 `u64`/`i64` 单调时钟或两原子值打包为一次写入；`source+timestamp` 用版本号或单一锁；统一 `updated >= created` 约束；所有时间差显式使用 saturating/wrapping 语义并加边界测试。

### 9.10 该域已核对但未列为发现

`parseFromSliceLeaky` 所有权与 `std.json` 契约一致，replay 用 `piece_arena`/`turn_arena` 管理借用页，长期保存值显式 `.alloc_always` 或复制；`settings_store.zig:574-708` 有 advisory lock、fingerprint 重试、随机临时名、fsync、rename 后 indeterminate 状态；凭据刷新经 `beginExistingMutation` 持锁，ChatGPT/Grok 保存失败会退役旧 session，凭据文件用 `durableReplaceVerified` 并尝试 `zeroAndFree`；单写 session 与 `tests/tla/session_manager/WriterLock.tla:110-121` 一致，未发现普通 resume 绕过锁并发写同一日志；session ID / blob hash / managed name / artifact handle 有字符集与路径组件校验，`VerifiedDir`/`openDirAbsoluteNoFollow` 对 symlink 有显式策略；`session_json.zig` 支持 legacy schema 1/2，`session_codec.parse_preferences` 支持 legacy `connection_id`/`model_id`/`ultrafast_mode`，v2 日志有新版本 read-only、未知 kind 跳过、CRC、torn tail 与 snapshot replay；settings 备份 5/3 保留上限、prompt history 1 MiB compact、web-fetch artifacts 50 MiB/1024 文件配额、v2 index 1 MiB compaction 与 `.tmp`/`.trash` sweep，未发现可证明的无限增长路径。

## 9.11 暂停状态（2026-11-06）

用户观察到疑似模型限流，要求全体暂停至次日恢复。已向仍在运行的代理发出暂停指令，要求它们交回进度快照后立即停止，不再重试失败请求、不再开新调查、不开新子代理。

已收口并写入本文的域（可直接进入修复）：CLI 与输出契约（§2）、工具与索引器（§3）、测试与 CI（§4）、跨平台与构建（§5）、Shell 链路（§7）、多子代理内存（§8）、会话/配置/持久化（§9）。

暂停时仍在收口、结论尚未写入本文的域：内存安全总域、核心运行时与控制流、权限与安全、UI 与交互、协议与网络、SDK 与 JS 层、性能与启动延迟、子代理嵌套与并发治理。这些代理的进度快照见 §10。

**暂停核实（主代理实测，2026-11-06 13:58）**：

| 检查项 | 结果 |
| --- | --- |
| `subagent status` | 17 个代理全部 `idle`，无一 `working` |
| `fx` 进程数 | 1 个（PID 49308，即主会话本身） |
| 该进程 TCP 连接 | 仅 1 条，`127.0.0.1:3425` 本地回环，无外部请求 |
| 25 秒内 `log.jsonl` 增长 | 仅主会话在写，其余静止 |
| 最后一批子代理活动 | 13:50:19 集中停止，与 `subagent stop` 时间吻合 |
| 线程数 | 174（全部子代理停止后仍保持高位，印证线程池不回收） |

**代理规模的真实统计（纠正先前口径）**：`.fx/sessions/v2` 下 223 个会话目录，其中 158 个为当日创建或更新；`index.jsonl` 显示存在三级结构（主代理 → 子代理 → 孙代理）。`subagent status` 只显示直接子，会低估总数。

恢复时必须先做的事：

1. 检查 `git status --short`，确认本轮只新增了 `docs/audit/2026-11-06-full-review.md`，产品代码零改动；并删除子代理产生的 `scripts/pgso/tests/__pycache__/`。
2. 用 `./zig-out/bin/fx` 复核 §0.3 的三项实测结论仍然成立（尤其 `zig build` 的 `AccessDenied`）。
3. 按 §11 台账从第 1 项开始，一项一验证，不要批量改。

## 10. 子代理嵌套与并发治理（实测实证）

本节的数据来自主代理直接读取 `.fx/sessions/v2/index.jsonl`，不是推断。

### 10.1 实测：231 个会话，嵌套深达 8 层

`index.jsonl` 的每条记录含 `id`、`role`、`host`、`parent`、`turns`、`created`、`updated`。按 `parent` 链还原深度后：

| 深度 | 会话数 | 含义 |
| --- | ---: | --- |
| 0 | 51 | 主会话（顶层 fx 实例） |
| 1 | 63 | 子代理 |
| 2 | 37 | 孙代理 |
| 3 | 41 | 曾孙代理 |
| 4 | 23 | 第四层 |
| 5 | 5 | 第五层 |
| 6 | 3 | 第六层 |
| 7 | 8 | 第七层 |
| **合计** | **231** | |

**单进程内出现 8 层嵌套，且最深一层仍有 8 个会话在活动**，是「代码层完全没有深度上限」的直接证据。

单个一级子代理带出的直接子会话最多 **11 个**（`D-Oh2sdZ-KLB`，即 `core-review`）。

层级实例：

```
pSdbC3jO7tQ_  (depth 0，当前 fx 主会话)
├── D-Oh2sdZ-KLB        (depth 1，core-review)
│   ├── _JqMKB3vMpRJ    (depth 2，turns=2)
│   ├── QUjKxIGfceNq
│   ├── xyhsx_9XuEpd
│   ├── ydbhQqPsVzAq
│   └── 2WsDe6zw2TDe    (合计 11 个直接子)
├── MNHovZYDXV3N        (depth 1，security-review)
├── 8sMlFnsU3B1o (depth 1，protocol-review)
├── MQxGCgmnERbA (depth 1，sdk-review)
├── CtC7RC_r6ymR
└── 39qV1ULHm8ZO
```

### 10.1.1 用户对代理嵌套的明确政策（2026-11-06）

用户在观察到上述规模后下达硬性要求，后续修复必须以此为准：

> 子代理不得再创建任何子代理。所有任务由对应的子代理自己独立完成，不再创建分支代理。

这意味着修复方向不是「限制层数」，而是**默认禁止嵌套**：子代理的工具集中不应包含 `subagent`，除非用户显式开启。当前实现恰好相反（`authority.zig:693-696` 注释与实现都默认保留 `subagent`）。

### 10.2 为什么 `subagent status` 会低估总数

该工具只返回**当前代理的直接子**。孙代理由子代理创建，父代理看不到。因此：

- 主代理视角：17 个
- 磁盘真实：223 个会话目录
- 差值几乎全部来自递归嵌套

**这是可观测性缺陷本身**：一个能递归创建子代理的系统，必须能报告全局树，否则连"开了多少"都答不出来。

### 10.3 代码层证据：`subagent` 被当作普通工具保留（已修复）

修复前 `src/core/subagent/authority.zig:612-614` 的注释写着：

> The host's tools a child may use: all of them, `subagent` included

`authority.zig:693-696` 的 `keepTool`：

> A tool the child keeps from the set it starts from, unless its profile leaves it out. `subagent` is kept like any other, so a child starts its own.

即**默认继承 `subagent` 工具，代码层没有深度上限**。`authority.zig:1031` 的 `tools=["*","!subagent"]` 只是 profile 示例，不是默认策略；测试 `:1074` 断言该 profile 能移除 `subagent`，说明限制只能靠人工写 profile 实现。

**现在的行为**：`keepTool` 对任何子代理一律拒绝 `subagent`，`authority.max_subagent_depth = 1` 写死，`tool_host.executeManaged` 对非 root 调用返回 `subagent_nested_forbidden`，两处注释同步改写。

### 10.4 并发层证据

| 位置 | 事实 |
| --- | --- |
| `child_state.zig:20` | `max_children = 256` 是**注册表容量**（`:363` 超限返回 `CapacityExceeded`），不是同时运行数 |
| `managed_owner.zig:232-275` | 每个 admitted work 立即 `std.Thread.spawn` 起 slot，**无 permit/gate/队列背压** |
| `agent_frame.zig:15` | `queue_cap = 64` 只管报告队列，不限制运行中数量 |
| `parallel_execution.zig:230-243` | 每个并行工具调用各起一条线程 |
| `src/main.zig:4126-4131` | `async_limit = .unlimited` |

### 10.5 实测后果

- 线程峰值 **312**；全部代理停止后仍 **174**，不回落。
- 进程空闲时 WS 3758 MB / Private 11598 MB，20 秒内**完全不变**（详见 §8.11）。
- 单进程承载 223 个会话的运行时，是上述数字的直接来源。

### 10.6 代码层根因：两层机制叠加，缺一不可

`nesting-review-2` 给出了完整链路，主代理已逐条核实：

**根因 A：每个子会话都获得自己的 subagent host**

`src/core/app/app_session_runtime.zig:1460-1461`（`attachChildV2Session` 末尾）：

```zig
// Its own subagents' state lives in its own log, as main's does.
enableSubagentHostV2(app, agent, v2);
```

`enableSubagentHostV2` 随即 `subagent_tool_host.Runtime.create(...)`。也就是说**子会话与主会话拿到完全相同的递归能力**。

**根因 B：`starts_subagents` 由「有没有 host」决定，而非「还有没有深度」**

`src/core/app/app_agent_runtime.zig:1211-1215`：

```zig
.starts_subagents = app_session_runtime.Runtime(App).ownSubagentHost(agent) != null,
```

`src/core/subagent/agent_adapter.zig:436-437`：

```zig
.admitted => |admitted| {
    if (subagent and !admitted.starts_subagents) return false;
```

因为根因 A 让每个子会话都有 host，`ownSubagentHost` 必非空，于是 `starts_subagents` 恒为真，`subagent` 工具必然保留。**没有任何 ceiling 参与判定。**

**根因 C：profile 默认放行**

`src/core/profiles/profiles.zig:246-248` 的 `allowsTool` 在 profile 未设置 `tools` 时 `return true`；`authority.zig:693-699` 的 `keepTool` 直接透传该结果。全仓 `grep max_depth` 只命中 MCP schema / JSON / shell 解析器，`src/core/subagent/` 下 `grep depth` 零命中；`generation` 只是 registry 版本号（`child_state.zig:221`），与层数无关。

### 10.7 并发层：三项独立的无上限

| 项 | 证据 | 后果 |
| --- | --- | --- |
| `Owner.start` 无 permit | `managed_owner.zig:264-275` 直接 `std.Thread.spawn`；唯一准入是 `closed`/`already_running`/`waiters != 0`，全按 `child_id` 判定，无全局计数 | 每个 child 一条线程 |
| 并行 subagent 前缀无上限 | `parallel_execution.zig:48-52` 的 `parallelSubagentPrefixLen` 无上限常量；对比同文件 `:66` 的 `max_parallel_host_calls = 16` | 一条消息里 N 个 subagent 调用 = N 线程 + N child，每个再递归 |
| `max_children = 256` 语义被误解 | `child_state.zig:20` + `:362-363`，`Registry` 按单个 `parent_id` 初始化（`:219-221`） | 是**每个父会话**的 children 数组容量；8 层树各有一份 256，全局上限是 256×层数 |
| `async_limit = .unlimited` 不可作为兜底 | `src/main.zig:4121-4131` 注释说明收窄会破坏 `HostName.connect` | 产品级限额只能做在 `Owner` 与 `parallel_execution` 两处 |

线程在 `destroySlot`（`managed_owner.zig:565-570`）里 join，只在 `start()` 的 `swapRemove` 路径或 host `deinit` 时触发；**没有全局 registry 追踪所有 owner 的 slot，因此一次性 stop 无法统一 join** —— 这直接解释了实测 312 → 174 的残留。

### 10.8 已发现但未处理的次要不一致（P2）

`agent_adapter.zig:430-431` 的旧引擎路径对 `subagent` 一律 `return false`，但 `src/core/cli/cli_ask.zig:278-287` 用 `subagent_available = true` 构建 child projection，而 `tool_projection.zig:568` 只在 `subagent_available` 为假时才剔除。结果：`fx ask` 的子代理在 schema 里**看得见** `subagent`，调用时却被 `childSees` 过滤，落到 `tool_host.zig:452` 的 `caller_unavailable`。既浪费轮次，也让模型困惑。

### 10.9 用户确定的控制面设计（已定案，非建议）

用户在观察到 231 个会话、8 层嵌套后明确了产品政策。以下为**定案要求**，实施时以此为准，不再讨论是否要限：

> 维持「一个主代理 + 少数几个一级子代理」的工作模式。一级子代理数量由用户在设置里自定义；**代码层禁止开二级子代理**，不允许再派独立代理。

因此设计与 `nesting-review-2` 的通用建议不同，按用户政策收敛为：

| 设置 key | 类型与范围 | 默认值 | 语义 |
| --- | --- | --- | --- |
| `subagent_max_children` | integer 1–16 | 4 | **一级**子代理的最大数量，用户可调 |
| `subagent_max_depth` | 固定为 1，**不暴露给用户** | 1 | 硬编码：主代理可派一级，一级不得再派 |

**关键约束：`subagent_max_depth` 不做成用户可配项，而是在代码里固定为 1。** 理由：

- 暴露成 0–8 的可配项等于允许用户把自己机器拖垮，而这恰恰是本次事故的成因。
- 「无限量的嵌套」没有对应的无限量资源与 token 预算，任何 N 层的配置都只是把爆炸推迟。
- 用户明确要求「不允许去开独立代理」，因此不提供开启入口。

**实施要点**：

1. `src/core/app/app_agent_runtime.zig:1211-1215` 的 `starts_subagents` 从「有没有 host」改为「有没有 host **且深度 < 1**」。
2. `src/core/subagent/authority.zig:693-699` 的 `keepTool` 对一级子代理**无条件剔除 `subagent`**，不再依赖 profile 是否写 `!subagent`。
3. `authority.zig:612-620` 与 `:693-696` 两处注释（"all of them, `subagent` included"、"so a child starts its own"）**必须同步改写**，否则会与新行为矛盾——这正是用户要求「代码和注释对齐」的直接场景。
4. 深度判定必须从 root 到当前 agent 的**父子链推导**，不能依赖 registry（registry 只记直接 children）。
5. `subagent_max_children` 只约束**一级**数量；超限时返回可操作错误，不静默排队。

**被拒时返回给模型的文本**（`model_contract.Result`，错误码上限 64 字节）：

- 二级拒绝：`error_code "subagent_nested_forbidden"`，result：`Subagents cannot start their own subagents. Do this work yourself with your own tools.`
- 一级超限：`error_code "subagent_children_exceeded"`，result：`{d} subagents already run under this session (limit {d}, set by subagent_max_children). Wait for a report or stop one with action "stop".`

**预期效果**：把实测的 231 个会话压到「1 主 + ≤4 一级 = 5 个会话」，线程数与内存随之从 O(N×上下文) 降到有界。

### 10.10 新增设置要同时落的 7 处（否则 CI shape 检查失败）

`nesting-review-2` 核对了 `max_agent_steps` 的完整接线，新增 key 必须同步修改：

| # | 位置 | 作用 |
| --- | --- | --- |
| 1 | `src/core/config/settings_keys.zig:126-127` | 声明 key、`.where`、`minimum`/`max_items` |
| 2 | `src/core/config/config_runtime.zig:1975-2030` | `parseProjectSafeFields` 白名单（仅当为 project-safe 时） |
| 3 | `src/core/config/settings_store.zig:123` | `Settings` 字段类型 |
| 4 | `src/core/config/env_settings.zig:104-110` | `FX_*` → key 映射 |
| 5 | `src/core/config/agent_steps.zig:9-25` | 解析语义（0 = 无限制，非法值忽略） |
| 6 | `src/core/app/app_lifecycle.zig:687,903` | 生效点 |
| 7 | `src/core/cli/cli_config.zig:440-445,990` | `resolved_keys` + 强制归类测试 |

### 10.11 分阶段修复顺序

| 阶段 | 内容 | 测试 |
| --- | --- | --- |
| 1 | admission 强制：在 `tool_host.zig:1522 admitManagedWork` 入口、`app_agents_runtime.zig:1655 addChild` 之前做深度与并发判定。深度须从 root 到当前 agent 的**父子链推导**，不能依赖 registry（registry 只记直接 children） | `tool_host.zig` 内联测试覆盖 depth 0/1/边界与错误文本；`child_state.zig` 加 `max_children` 边界测试 |
| 2 | 可见性收敛：把 `agent_adapter.zig:437` 的 `starts_subagents` 改为三元判定 `host != null and depth < max_depth`，并让 `cli_ask.zig:285` 共用同一函数（同时修掉 §10.8） | `agent_adapter.zig` 内联测试断言达到上限时 `subagent` 不出现在 `childToolNames` 与 `childFunctions` |
| 3 | 线程 permit：`managed_owner.zig:232 start` 加 permit；`parallel_execution.zig` 加 `max_parallel_subagent_calls` | 两处内联测试：permit 耗尽返回新错误；分组长度被截断 |
| 4 | 配置接线：按 §10.10 七处 | E2E 扩展 `tests/e2e/tui-host-instances.test.ts`（**已在 corpus 与 shard weights 中分类，扩展现有文件无需改清单**） |

若新建 `tests/e2e/*.test.ts`，必须同时加 `scripts/pgso/corpus.json` 分类、`tests/e2e/ci-shard-weights.json` 权重，分支 `process.platform` 时还要加 `tests/e2e/macos-platform-tests.json` 条目，`ci-shards.test.ts` 会校验。

**结论**：§10.6 的根因 A/B/C 与 §10.7 的三项无上限**互相独立，任一条单独存在都足以造成 231 个会话、312 线程的规模**。只修深度能压住层数，但单层 11 路并发的分叉仍需 permit 与并行上限封住。建议阶段 1 与阶段 3 同批落地。



## 11. UI 与交互

来源：`ui-review-2`，31 个文件，12 条发现。主代理已核实第 1 条。

### 11.1 P1：正文与工具输出中的 ESC 字节不过滤，可注入终端控制序列

- 证据（**主代理已核实**）：`src/core/shared/text_utils.zig:19-22`

  ```zig
  pub fn isModelSafeText(text: []const u8) bool {
      if (std.mem.findScalar(u8, text, 0) != null) return false;
      return std.unicode.utf8ValidateSlice(text);
  }
  ```

  只拒绝 NUL 与非法 UTF-8，**ESC 被判定为安全**；`sanitizeModelText`（`:560-563`）原样放行。`encodeTerminalSafe` 只用于 CLI 单行、审批单行、footer，**未覆盖 transcript 正文**。
- 触发：让工具输出含 `\x1b[2J`、`\x1b]0;pwned\x07`、`\x1b[?1049h` 的文本（例如 `cat` 一个恶意 README），或让模型回显该串。
- 后果：清屏、改窗口标题；`?1049h` 会把 fx 推进交替屏并破坏后续布局。属渲染正确性与安全交叉问题。
- 修复：在 transcript 写入与工具输出投影处统一「保留 SGR、丢弃其余 C0/CSI/OSC」，复用 `display_width.ansiSequenceEnd` 做白名单判定。

### 11.2 P1：正常退出未恢复自动换行（DECAWM 关）

- 证据：`src/core/app/app_lifecycle.zig:48` 的 `normal_exit_restore_prefix` 不含 `\x1b[?7h`；异常退出序列 `:45` 有 `\x1b[?1049l\x1b[?7h`，`emitShutdownCleanupAndResume` 在 `:1654` 也单独补了 `\x1b[?7h`。进入交互模式时 `src/ui/terminal/terminal.zig:5` 明确写了 `\x1b[?7l`。
- 触发：正常退出（`/exit`、Ctrl+D）后，在同一窗口贴入超过终端宽度的长行。
- 后果：若清理输出未执行（写失败被 `catch {}` 吞掉），shell 处于不换行状态，长命令与提示符覆盖同一行，只能靠 `reset` 恢复。
- 修复：补 `\x1b[?7h`，并把三条序列合成一个常量消除漂移。

### 11.3 P1：文件审批屏在 5–7 行终端只画 3 个选项，无文件身份、无按键提示

- 证据：`src/ui/approval_screen.zig:690-704`（`choice_rows = @min(3, rows)`）、`:285-293`。`paintCompactFileApproval` 只画 `.choice` 行，不画 header/divider/hint，也不设置 `file_identity_visible`。
- 触发：终端高度 6 行（fx 允许 ≥5 行，`app_entry_runtime.zig:252`）时触发文件写入审批。
- 后果：用户看不到正在批准哪个文件、看不到 `y/n` 提示。
- 修复：紧凑布局至少保留一行身份（文件名 + 路径尾部）与一行 `y/n/a/d` 提示。

### 11.4 P2：审批屏每次绘制重建整份文档布局

- 证据：`src/ui/approval_screen.zig:317-322` 每次 `paintFileApproval` 都 `TranscriptDocumentLayout.init(alloc, transcript, layout.cols)`，遍历全部字节并每 64 行记 checkpoint（`:81-113`）；测试自带 50,000 行用例（`:2041-2051`）。
- 后果：长会话审批滚动明显卡顿。
- 修复：按 `(transcript 版本, cols)` 缓存 layout。

### 11.5 P2：Windows 无 SIGWINCH 却按 8ms 轮询

- 证据：`src/ui/resize_runtime.zig:28-45`（`supports_resize_signal` 不含 `.windows`）、`:271-284`；`src/main.zig:187-188` 的 `active_poll_timeout_ms = 8`。
- 后果：空闲 CPU 与电池消耗偏高；拖动结束最多 8ms 才重排。
- 修复：Windows 改 100–200ms 按需轮询。

### 11.6 P2：`catalog_menu` 这个 owner 在生产代码中没有进入点

- 证据：`src/ui/shell_runtime.zig:67-72` 定义三类 owner；`enterCatalogMenuScreen` 的唯一调用是测试 `app_lifecycle.zig:2183`；`app_input_runtime.zig:10599` 只在测试里赋值；渲染侧 `app_render_runtime.zig:1169/1183/1232` 只有防御清理。
- 后果：文档声称三类 owner 独占交替屏，实际只有两类工作。
- 修复：删除该枚举与分支，或真正接线。

### 11.7 P2：审批屏滚轮固定 3 行，无页级滚动

- 证据：`src/ui/approval_screen.zig:28`（`document_scroll_wheel_rows: i32 = 3`）、`:609-614`。无 PageUp/PageDown/Home/End 分支。
- 后果：2000 行文件需数百次滚动。
- 修复：按半屏或累积加速，补齐页级按键。

### 11.8 P2：全屏 transcript 进入失败路径只 `catch {}`

- 证据：`src/core/app/app_lifecycle.zig:1507-1516`，`errdefer` 里 `leaveFullTranscriptScreen(...) catch {}` 与 `setFullTranscriptProjection(.inline_mode) catch {}` 都吞错误。
- 后果：恢复写失败时 `alternate_screen_owner` 可能已置位但屏幕未恢复，出现空白或重影。
- 修复：恢复失败至少记 `debug_trace` 并把 owner 归零。

### 11.9 P3 项（四条）

- **退出时无条件发 `\x1b[?1004l`**（`app_lifecycle.zig:45/48`），但产品路径从未 `\x1b[?1004h`（`grep 1004h` 只命中 `engine.zig:4810` 的影子 VT）。建议删除或成对补。
- **非 macOS 静音只回落 BEL**（`notifications/sound.zig:11,160-174`）：`default_enabled` 仅 macOS 为 true，`play` 直接 `emitBell()`。建议文案改成「终端响铃」。
- **极窄终端截断无可见标记**（`approval_screen.zig:1322-1333`、`footer/approval_ui.zig:1637`）：`prefixByWidth` 不追加省略号，路径尾部被静默吃掉，容易误批；建议用 `suffixByWidth` 保留尾部并加 `…`。
- **resize 只在列数变化时失效 footer**（`src/main.zig:3308-3313`）：仅 `cols` 变化才重排，纯行数变化不触发。

### 11.10 该域已确认正确

`resize_runtime.zig:47-92` 的 `ResizeApprovalInterlock`、`input/terminal_action_decoder.zig:33-45` 的粘贴优先与转义超时、`terminal/terminal.zig:23-28` 的 `alternateScreenFrameRestoreSequence` 设计正确且有单测覆盖；`shared/display_width.zig` 对 ZWJ、VS15/16、keycap、组合字符与 RGI 序列处理完整，未发现宽字符错位。

## 12. 性能与 CPU 占用

来源：`perf-review-2`，34 个文件，8 条发现。主代理已核实第 1、2 条。本域直接解释了 §8.11 记录的「134 分钟烧掉 129.6 分钟 CPU、但空闲时 CPU 为 0」。

### 12.1 P0：活跃期 1ms 忙轮询，每轮还做全量 facts 收集

- 证据（**主代理已核实**）：`src/main.zig:216-225`

  ```zig
  if (next_iteration_due) return 0;
  return if (first_frame_pending or
      auth_refresh_active or
      skills_refresh_active or
      transcript_page_work_active or
      file_listing_hold_pending)
      @min(default_timeout_ms, focused_ui_worker_poll_timeout_ms)
  else
      default_timeout_ms;
  ```

  `next_iteration_due` 为真时**超时直接为 0**（不等待）；任一派生状态活跃时，超时被压到 `focused_ui_worker_poll_timeout_ms = 1`。`src/ui/event_loop.zig:91-95` 每轮无条件调用 `collect_facts` → `loopCollectFacts`（`src/main.zig:3226-3386`，约 40 次子调用，含 `syncRecord`、`collectThemeFacts`、`collectResizeFacts`、`prewarmFullTranscriptPage`）。
- 触发：任何流式输出或工具执行期间，上述状态几乎全程命中。
- 后果：每秒最多 1000 次循环，每次伴随完整 facts 收集。这就是「空闲 0%、活跃期平均 0.97 核」的直接原因。
- 修复：把 1ms 超时限制在真正等待的短窗口；改为等一次 `waitTimeout` 到首个事件，而不是按帧轮询；`poll=0` 分支之间加最小间隔。**只改等待时长，不动状态机语义。**

### 12.2 P1：流式文本每 tick 做一次前移式 memmove（O(n²)）

- 证据（**主代理已核实**）：`src/ui/assistant/pacer.zig:425-431`

  ```zig
  fn consume(self: *AssistantPacer, byte_count: usize) void {
      const remaining = self.pending.items.len - byte_count;
      if (remaining > 0) {
          @memmove(self.pending.items[0..remaining], self.pending.items[byte_count..]);
      }
      self.pending.items.len = remaining;
  }
  ```

  `enqueue` 只 `appendSlice`，`consume` 把剩余字节整体搬到队头。叠加 §12.1 的 1ms 轮询，`tickAgentInContext`（`src/main.zig:3544`）每轮执行 `pacer.tick`；一帧只消费一小段时，长回答被反复整体左移，形成 O(n²) 字节搬运（100KB 回答会放大到百万级字节复制）。
- 修复：改用读偏移 `emitted_off` 替代搬移，队空时再一次性 `clearRetainingCapacity`。

### 12.3 P1：每次构建状态栏都 `stat` 一次 `.git/HEAD`

- 证据：`src/core/workspace/statusline_identity.zig:106-131`、`src/core/app/app_render_runtime.zig:900-909`。`buildStatuslineItems` 每次渲染都调 `workspace_identity.refresh` → `refreshBranch` → `std.Io.Dir.cwd().statFile(.git/HEAD)`；只有 inode+mtime+size 未变才对文件内容短路，**系统调用本身每次都会发生**。
- 后果：帧率受 §12.1 驱动，每秒最多上千次同步系统调用。
- 修复：给 `head_path` 加 250ms 时间节流（与 MCP 状态一致）。

### 12.4 P1：无 turn summary 的长会话每帧全量重渲染

- 证据：`src/core/app/app_worker_runtime.zig:937-973`、`src/ui/transcript/runtime.zig:12850-12871`、`src/ui/transcript/source_preparation.zig:1197-1204`。`markTranscriptContentDirty` 递增 `full_transcript_content_revision`，缓存 `CompactTranscriptSourceCache.find`（`runtime.zig:4621-4638`）以 `content_revision + cols + has_committed_frame` 为键，revision 一变必然未命中。
- 缓解机制确实存在（`frozen_prefix` 断点续渲染），但 `frozen_prefix.zig:141-151` 的 `boundary` 只在「最后一个 turn_summary 之后」切分；**没有 turn summary 的长会话中 `limit=0`，全程无法复用**，导致每帧全量重渲染 + 全量 `bytes` 复制（`source_preparation.zig:406-456` 至少 8 次 dupe）。
- 修复：允许以「已完成 entry 前缀」作为可复用断点；key 的哈希覆盖不变即可保证正确性。

### 12.5 P2：固定点求解每轮迭代重做准备

- 证据：`src/ui/render_engine/frame_fixed_point.zig:36-93`、`src/core/app/app_render_runtime.zig:2155-2271`。`solve` 循环中 `prepare_candidate` 每次都 `prepared.deinit` 后重跑 `prepareTranscriptSurfacePaintFromSourceForFrame`（`painter.zig:1693-1916`，逐行分配并计算 `visualRowsForLine`）。`precomputed_plain_lines` 快路径（`painter.zig:1843-1854`）在流式输出时因 `effective_replaceable_last_line` 恒真而不成立。
- 修复：把「行布局」与「selection」解耦，迭代只重算 selection，行布局按 source 指针缓存。

### 12.6 P2：每轮 facts 都提交帧尝试，无合并

- 证据：`src/core/app/app_render_runtime.zig:2100-2109`、`src/ui/event_loop.zig:121-122`。`run` 循环尾部无条件 `settle_delivery_epoch` + `commit_frame`，`loopCommitFrame`（`src/main.zig:3550-3570`）内还有两次 `flushRequestedFrame`。
- 修复：与 §12.1 一并处理，事件驱动替代周期轮询即可自然消除。

### 12.7 P2：日志关闭时仍取全局互斥锁

- 证据：`src/core/shared/debug_trace.zig:97-104,379-386`。每个 `logf` 先 `noinline begin()`，`begin` 内 `isScopeEnabled` 取 `state_mutex.lockUncancelable` 并检查 `state.enabled`。**未启用时格式化确实被跳过**（比预期好），但每条 trace 仍付一次全局锁。
- 修复：把 `enabled` 做成原子布尔快路径，仅在已使能时才加锁读 filter。

### 12.8 P3：每轮 facts 都执行 MCP 菜单/补全刷新

- 证据：`src/core/app/app_commands.zig:347-360`、`src/main.zig:1904-1906`。`collectMcpHostFacts` 每轮调用 `applyMcpHostReload` → `refreshMcpHost`、`refreshMcpCompletion`、`refreshMcpHostMenu`、`refreshMcpHostStatus`；只有最后一个自带 250ms 门（`app_mcp_runtime.zig:237-239`），其余无节流。
- 修复：给 `refreshMcpCompletion`/`refreshMcpHostMenu` 加同样节流，或无 MCP 服务器时提前返回。

### 12.9 该域未覆盖

`benchmarks/startup.sh` 与 `bench.yml` 的具体预算数值、`scripts/pgso/` 语料分类细节、`src/core/indexer/` 遍历剪枝实际开销、`src/core/terminal/`、`src/core/config/`、`src/ui/render.zig`。启动冷路径（`fx help` <2ms）在所读代码中未见明显多余 I/O，未发现回归点。

**关键判断**：§12.1 与 §12.2 是**互相放大**的关系——1ms 轮询提高了 `consume` 的调用频率，而 `consume` 的 O(n²) 搬运又拖长了每轮耗时。修 §12.1 能大幅降低总功耗，修 §12.2 能消除长回答时的额外尖峰。两者应同批处理。

## 13. 核心运行时与控制流

来源：`core-review-2`，34 个文件，8 条发现。主代理已核实第 3 条。

### 13.1 P1：默认无步数上限，nudge/continuation 也没有独立预算

- 证据（**主代理已核实**）：`src/core/config/agent_steps.zig:3`、`:23-25`

  ```zig
  pub const default_max_agent_steps: usize = 0;

  pub fn allowsStep(limit: usize, completed_steps: usize) bool {
      return limit == 0 or completed_steps < limit;
  }
  ```

- 触发：默认配置（未显式设置 `max_agent_steps`）。
- 后果：`orchestrator.zig:7111` 的 `while (agent_steps.allowsStep(...))` **永不因步数退出**。`9225-9258` 的空回复 nudge、`9213-9222` 的 silent-tool continuation、`9128-9140` 的 length-limited resend 全部以 `allowsStep(limit, step+1)` 为唯一闸门，因此每一项都可各自无限重复。模型持续返回空回复（`finish_reason = other`）时每步消耗一次真实 API 调用，直到用户按 Esc。`empty_reply_nudged` 在 `9205` 被任何非空回复重置，长任务中可反复触发。
- 修复：默认改为有限值；`0` 应表示「显式无上限」且需用户明确选择；nudge 与 continuation 各加独立小预算。

### 13.2 P1：并发恢复失败导致 ticker 线程永久泄漏

- 证据：`src/core/agent/runtime/orchestrator.zig:7926-7928`

  ```zig
  request_recovery.beginSend();
  const streamed = streamMainCompletion(deps, arena, model_request);
  request_recovery.endSend();
  ```

- `endSend` 只在正常返回后执行；但 `streamMainCompletion` 有第二处提前返回（auth replay 在 `8134-8150` 重新赋值后再次调用）与 cancel 分支的 `return`。`beginSend` 仅在 `self.ticker != null` 时跳过启动，而 **`endSend` 才是把 `self.ticker = null` 复位的地方**。
- 后果：`ticker` 非空、`ticker_stop` 已置真却未 join，状态机与 `state.phase` 脱节，重试倒计时不再刷新。
- 修复：每条 send 路径改用 `defer`/`errdefer request_recovery.endSend()`。

### 13.3 P1：`closeActive` 拿不到锁时静默返回 false，崩溃记录丢失但日志宣称已保存

- 证据：`src/core/agent/runtime/request_recovery.zig:182-196`（两处 `lockWithin(..., close_wait_ms)` 失败即 `return false`）。
- 触发：SIGHUP/SIGTERM 到达时 turn 线程正持 `self.mutex`（send 期间的 `responding`、`stepLocked`、`showLocked` 都持锁，`showLocked` 还会调 host 回调）。
- 后果：`app_lifecycle.zig:114` 只把 `saved` 写进 trace（`record_saved=false`）后照常退出；磁盘无 clean 记录，下次启动把这次死亡算作 `abrupt_deaths +1`，两次后弹 `crash_loop` 要求用户确认。
- 修复：提高 `close_wait_ms` 覆盖一次 host 回调，或失败时置显式「未保存」标志供启动读取。

### 13.4 P2：`TurnFinalizationGuard.finish` 在 `push_event` 失败时留下「已 emitted 但未送达」

- 证据：`src/core/agent/runtime/finalization.zig:147-160`。`self.state = .emitted` 先置位，随后 `push_event` 可能因 OOM 或队列满失败；重入 `finish` 走 `126-136` 的 duplicate ignored 直接 return。
- 后果：session 里 turn 已 finalize，宿主永远收不到 `finish_prompt`，UI 流状态停在 active。
- 修复：先 `push_event` 成功再置 `.emitted`，或失败时回滚为 `.open` 并把 `finished_prompt` 归还调用方。

### 13.5 P2：`pending_permission` 等待错误被当作正常唤醒，静默合成 deny

- 证据：`src/core/agent/runtime/worker_runtime.zig:2736-2741`

  ```zig
  while (self.pending_permission_response == null and !self.worker_stop_requested) {
      self.worker_cond.wait(io_mod.getIo(), &self.worker_mutex) catch break;
  }
  const response = self.pending_permission_response orelse
      permission_request.OwnedPermissionResponse.init(alloc, .deny, null);
  ```

- 后果：等待失败时 `pending_permission_response` 为 null，**静默合成 deny** 返回给工具层；UI 审批面板可能仍显示（`cancelApprovalOperation` 依赖 `isCancelRequested()`，此处未置位）。用户看到「什么都没点，工具被拒绝」。
- 修复：区分 `error.Timeout`/取消与其他错误；前者回循环，后者置 cancel 标志并清 UI。

### 13.6 P2：`PreToolUse` hook 失败时错误来源被压成单一常量

- 证据：`src/core/hooks/runtime.zig:295-301`、`src/core/agent/runtime/lifecycle.zig:388-398,468-471`。`HandlerFailed`/`Cancelled`/`InvalidHandlerOutput`/`HandlerOutputTooLarge` 全部映射为 `error.LifecycleFailedClosed`，模型只收到不含 hook 名与原始错误的 `preToolUseFailedClosedJson`。
- 后果：模型会不断重试同一调用，与 §7 的「重复失败终止」问题叠加。
- 修复：`.lifecycle_failed_closed` 分支带上 hook 名与 `@errorName`。

### 13.7 P3：`shell_execution_failure_retry` 跨 turn 残留

- 证据：`src/core/agent/runtime/tool_admission.zig:291-306`、`:268-270`。`beginBatch` 只清 `current`；若该 step 在 `finishBatch` 前因 cancel/错误提前 `return`（`orchestrator.zig:11020`、`11134`），`current` 不清、`previous` 不换，下一次 batch 历史错位。
- 后果：streak 跨 turn 延续，新 turn 首个相同的失败 shell 调用就触发 `repeated_shell_execution_failure` 并结束整轮。
- 修复：cancel/中断返回路径前调用 `deinit(arena)` 重置。

### 13.8 P3：`context_overflow_recovery` 的 `.pending` 状态可能直接失败

- 证据：`orchestrator.zig:7661-7678`、`:7843-7846`。`has_new_compactable_context = !just_rebuilt_request`；若 provider 连续两次拒绝同一请求，第二次发生在 `just_rebuilt_request` 之后，则 `wants_compaction` 为假而 `overflow_pending` 仍为真，直接 `return error.ContextCapacityExceeded`，即使 `compaction_history` 里还有可压缩的更早 turn。
- 修复：`.pending` 至少允许一次不受 `just_rebuilt_request` 限制的重试，或强制走 `kept = 0` 分支。

### 13.9 该域未覆盖

`src/core/execution/command_runner.zig` 的超时/进程树细节、`src/core/app/app_entry_runtime.zig` 的启动与 `FX_BENCH` 路径、`src/core/agents/child_run.zig` 与 `app_agents_runtime.zig` 的 slot 线程全量生命周期、`src/core/compactor/summarize.zig` 的 notes 回退分支。

## 14. 协议与网络

来源：`protocol-review-2`，14 个文件，7 条发现。

### 14.1 P1：Anthropic 路径缺 JSON 深度检查，safe 构建下会 abort

- 证据：`src/gateway/anthropic_messages.zig:416-424`（`applyJson` 直接 `parseFromSlice`，无 `json_depth.exceeds`）、`:604-608`（`appendJsonValue` 用 `std.json.Stringify.value` 序列化 `content_block.input`）。该文件内 `grep json_depth` 无匹配。
- 触发：Anthropic 兼容 provider 返回深度 >256 的 `input`。
- 后果：按 `json_depth.zig:1-4` 的注释，`Stringify` 在 safe 构建中超过 256 层会 **abort（进程级崩溃）**，不是可恢复错误。其它协议路径（`client.zig:4450`、`responses_protocol.zig:925`、`chat_completions_protocol.zig:682`）都已加此检查，**此处是唯一遗漏**。
- 修复：在 `applyJson` 入口加 `json_depth.exceeds(payload)`，并在 `appendJsonValue` 前再校验 `input`。

### 14.2 P2：SSE 总量上限可被注释行绕过

- 证据：`src/gateway/sse.zig:93-99`（`consume` 仅在 `max_total_bytes != null` 时累计）；`chat_completions_protocol.zig:1015` 构造 `sse.Reader` 时**没有设置 `max_total_bytes`**；总量由 `Reducer` 的 `json_bytes` 单独累计（`:673`），但被 `ignore` 的注释行、`event:`、`id:` 行不计入。
- 触发：恶意兼容 provider 在事件间插入大量 `:` 注释行（`client.zig:9981` 说明 keep-alive padding 是正常形态，单条可达 66 KiB）。
- 后果：单次流可长时间消耗带宽与解析 CPU，不触发任何上限；超时只靠 `ConnectionWatch` 的停顿检测，持续发注释就永不停顿。
- 修复：给 `consume_stream` 的 `sse.Reader` 设 `max_total_bytes`，与 `chat_completions.zig:348,415` 一致。

### 14.3 P2：Anthropic 工具参数 `input` 无字节上限

- 证据：`anthropic_messages.zig:494-501`（`input_json_delta` 只 `appendSlice`，无上限）、`:365`（`finish` 直接 `dupe` 成 `arguments_json`，不调 `validate_arguments`／`check_json_depth`）。对比 `chat_completions_protocol.zig:594` 有 `arguments_bytes = 1 MiB`。
- 后果：单条流内可无限增长内存（受 `sse.max_total_bytes` 32 MiB 约束，仍是 32 MiB 级放大）；畸形/超深参数被当作合法 tool call 交给下游。
- 修复：给 `Block.input` 加与 Chat Completions 对齐的上限，`finish` 中复用 `validate_arguments`。

### 14.4 P3：`StreamTooLarge` 与 `EventTooLarge` 被混为一谈

- 证据：`chat_completions_protocol.zig:1015,1020`。`framing.max_total_bytes = framing.total_bytes + @min(limits.event_bytes, remaining)`，随后把 `StreamTooLarge` 一律解释为 `EventTooLarge`（当 `event_limited`）。
- 后果：`chat_completions.zig:317-325` 只能用同一套恢复策略，可能把应整体重试的流当成畸形流。
- 修复：先判 `total_bytes >= total_wire_bytes` 再判事件级，分别返回两类错误。

### 14.5 P3：MCP HTTP 错误路径不消费响应体

- 证据：`src/mcp/io/http.zig:445-447`（401/403 直接 `return .rejected` 不读 body）、`:618-619`（`fetchRun` 用 `.limited(1 << 20)` 读，失败静默置 null）、`:457`（非 JSON content-type 直接 `.http_failure` 不读 body）。
- 后果：连接无法被 `takeKept` 复用（`closedByServer` 在 `:710` 会发现残留字节），每次新建连接，弱网/重试下放大连接数与 TLS 握手成本。不会卡死。
- 修复：错误路径显式丢弃或限读剩余 body 后再返回。

### 14.6 P3：MCP `run` 无请求级超时

- 证据：`src/mcp/io/http.zig:418-428` 的 `receiveHead` 无 deadline；超时依赖 `request.zig:64-74` 的 `idle_ms = 60_000`/`hard_ms = 600_000` 在 core 层计时。`fetchRun` 未见对应超时。
- 后果：若 core 计时器未覆盖某条 `fetch` 路径，请求会一直占用 slot，直到 `max_in_flight + waiting_room = 64` 占满。**置信度低，该路径超时来源未完全确认。**
- 修复：确认 `fetch` 是否被 `request.zig` 的 Timer 覆盖；若无，给 `fetchRun` 加独立 deadline。

### 14.7 P3：`tool_names.zig` 别名切片依赖隐式拼接格式

- 证据：`src/core/mcp/tool_names.zig:44-67`。`server_end = owned_key.len - tool.len`，`aliases` 的 value 是 `owned_key[server_end - server.len .. server_end]`，依赖 identity 一定是 `{server}{tool}` 直接拼接。
- 后果：当前无 bug，但任何对 identity 格式的修改（加分隔符或长度前缀）都会让「Borrows the server identity」这一隐式不变量失效并越界。
- 修复：把 `server` 偏移单独存进 struct，或独立分配 `server_name`。

### 14.8 该域未覆盖

`src/core/mcp_host/mcp_call_bridge.zig` 仅读前 400 行与 `readRequestLine`/`Watch` 段，未审并发与取消全路径；`src/usage/` 只确认 `report.zig` 使用饱和加法 `+|`；`src/acp/jsonrpc.zig` 的 `parseMessage` 未校验 `jsonrpc` 字段与重复键（`:86-128`），未读到 server 侧补偿，故未列为发现。

## 15. SDK 与 JavaScript 层

来源：`sdk-review-2`，34 个文件，8 条发现。全部为 JS 侧资源清理与竞态问题。

### 15.1 P1：WASM HTTP 流泄漏

- 证据：`sdk/wasm-runtime.js:929-932`。`fx_http_stream_close` 只从 `streams` 删除句柄并调 `controller.abort()`；当核心未关句柄就退出、或 `streamOpen` 之后 request 已 settle 时，`state.reader` 从未 `cancel()` 或 `releaseLock()`，`streams` 持续增长。`streamNext`（`:355-398`）读取失败只置 `readError`；`abortHostEffects`（`:869-874`）也只 abort 不删句柄。
- 修复：统一 `closeStream(handle)` 做 `controller.abort()` + `reader.cancel()` + `releaseLock()`，在 `markExited` 与流结束时调用，确保 `streams.clear()`。

### 15.2 P2：`streamOpen` 的 reader 无归属清理

- 证据：`sdk/wasm-runtime.js:310-338`。`state.responseSettled` 只捕获 `state.responseError`，`getReader()` 的 reader 没有清理归属；body 读到一半且句柄被 close 时，`controller.abort()` 对已 settle 的 fetch 不再生效，body 流仍挂着。
- 修复：close/abort 路径显式 `state.reader?.cancel()`，不依赖 AbortSignal。

### 15.3 P2：`node.js` fetch 清理的 drain 分支永不可达

- 证据：`sdk/node.js:405-443`。`cleanupAction(state)` 在 `settled=true` 时把 `alive` 设为 false，因此只能返回 `"abort"` 或 `"done"`；`finish()` 里 `cleanupAction(state) === "drain"` 分支永不成立，`beginDrain`/`state.timer`（`:412`）到不了，`void state.done.then(destroy)` 不执行，`clearTimeout(state.timer)`（`:521`）只清未启动的 timer。
- 后果：核心先退出但响应没读完的路径直接 abort+destroy，`state.done` 无消费者，`pumpFetch` 的 finally 与 destroy 之间无保证。
- 修复：`finish()` 用未叠加 settled 的原始状态判断，或删除死分支。

### 15.4 P2：`fetchState` 是模块级单变量，多并发请求互相覆盖

- 证据：`sdk/node.js:447-456,520-529`，`drainReady`（`:531-543`）也用同一个变量。核心同时发起多个请求时，第二个 `pumpFetch` 覆盖 `fetchState`，第一个请求的 `controller.abort()`（`abortHostEffects`，`:414-420`）再也拿不到，取消时可能漏掉正在跑的 fetch。
- 修复：改为 `Map<handle, state>`，`abortHostEffects` 遍历全部 abort。

### 15.5 P2：输出背压只有一个 resolve 槽，等待者永久悬挂

- 证据：`sdk/engine.js:2267-2280`。`resumeOutput` 只有一个槽，`queue` 满时每次 `push` 覆盖它（`:2271`），前一个 `capacity` Promise 的等待者永久悬挂；`cancel()`（`:2357`）与 `finally`（`:2458`）只 resolve 最后一个。
- 修复：改成等待者队列，或只允许一个等待者、其余排队。

### 15.6 P2：turn 结束时 `toolControllers` 只 clear 不 abort

- 证据：`sdk/engine.js:2474`（`clear()` 而不 abort）、`executeHostTool` 的 controller 在 `:1558` 加入、`:1601` 删除。turn 结束而工具 Promise 挂起时，`clear()` 不 abort，宿主工具持续运行并继续持有 `signal`。
- 修复：`finally` 里对剩余 controller 逐个 `abort()` 再 `clear()`。

### 15.7 P2：`durable.js` 租约续期错误被吞

- 证据：`sdk/durable.js:2086-2091`。`chained()` 失败时只有 `isFenced` 才取消 turn，网络/存储错误静默丢失，interval 继续触发，不上报 `session.error`。
- 修复：非 fenced 错误上报 `agent.emit("session.error")`，连续失败后停止续期。

### 15.8 P2：`subscription.js` 刷新去重绑定单个调用者的 signal

- 证据：`sdk/subscription.js:208-218`（`refreshing: Map` + `.finally(delete)`）、`:181-195`。共享任务未接收 signal；第一个调用者 abort 后 `spec.refresh` 因 AbortError 失败，共享 `task` 对后续调用者整体失败。`redeem` 在 `refreshLock` 分支还会再调一次 `credentials()`（`:184`），可能与 `current()`（`:221`）读取结果不一致。
- 修复：共享 refresh 不绑定某个调用者的 signal，或每个等待者单独 `Promise.race` 处理自己的 signal。

### 15.9 该域未覆盖

`sdk/durable/world.mjs`、`sdk/tests/next/**`、`sdk/types/*.d.ts`、`src/acp/libfx_hooks.zig`、`src/acp/libfx_journal.zig`、`src/acp/libfx_steering.zig`、`src/core/hosts/**`、`sdk/browser-test-terminal.html` 后半段、`sdk/term-demo.html`、`sdk/skills*.js`、`sdk/mcp.js`、`sdk/custom-provider.js`、`sdk/grok*.js`。`package.json` 的 `exports`/`types` 对齐、CJS/ESM 互操作、Windows 路径未发现新增问题。

## 16. 内存与资源（泄漏类）

来源：`mem-review-2`，26 个文件深读 + 344 个 `.zig` 全量 grep，8 条发现。本域补充了 §8 中「资源不归还」的**具体驻留对象**。

### 16.1 P1：退出超时后仍销毁 MCP sink，后台线程可 use-after-free

- 证据：`src/core/app/app_mcp_runtime.zig:379-395`（配 `:676-679`、`:1032-1052`）。等 5 秒（`waited < 500` × 10ms）后若 `host_verbs > 0` **只记日志**，继续执行 `sink.deinit(); c_allocator.destroy(sink); self.host_sink = null;`。
- 触发：`/mcp show` 正在连慢服务器或菜单工具加载未完成时退出 fx，5 秒未结束。
- 后果：`VerbJob.run`（`:697-727`）与 `MenuToolsJob.run`（`:1032-1052`）仍持 `sink` 指针并在 `sink.push`/`sink.mutex` 上操作，`destroy` 之后是 use-after-free，表现为退出瞬间崩溃或卡死。
- 修复：超时后不销毁 sink，标记 retired 并等引用计数归零；或用 `waitRetired` 同款机制统一等待。

### 16.2 P2：终端启动失败路径只 kill 不 wait，子进程成僵尸

- 证据：`src/core/terminal/native_session.zig:1728-1729`（`errdefer if (child_owned) child.kill(...)`，**无 `child.wait`**）、`:1747`、`:1757-1770`、`:1815-1817`，另 `:441-457` 同类。
- 触发：launcher 配置过大、`LauncherInputMissing`/`LauncherControlMissing`/`LauncherNotPrepared`，或 `deinit` 时 `backend_started` 为假。
- 后果：`Child.kill` 只发信号不回收，POSIX 上每次失败留一个 zombie 与未关闭的 pipe/pty fd；反复失败会累积 pid 与句柄。
- 修复：所有 errdefer 分支改为 `kill` 后 `_ = child.wait(io)`，或统一 `terminateAndReap` 辅助函数。

### 16.3 P2：恢复状态 ticker 持锁调用宿主回调（锁内做 I/O）

- 证据：`src/core/agent/runtime/request_recovery.zig:406-423`。`self.mutex` 在整个 ticker 循环内持有，`stepLocked(.tick)` 内部经 deps 发布状态（TUI 拷贝+入队、ACP 格式化并写帧）；`endSend`（`:371-380`）需同一把锁。
- 后果：宿主回调一旦阻塞，`endSend`/`deinit` 一起被拖住，形成锁序风险与退出卡顿。
- 修复：锁内只推进状态并拷贝待发布事件，解锁后再调宿主。

### 16.4 P2：terminal backend 明确「留到进程退出」，注册表与 store 永不归还

- 证据（**主代理已核实**）：`src/core/terminal/client.zig:466-479`

  ```zig
  if (self.backend_drained) {
      backend.registry.deinit();
      backend.store.deinit();
      alloc.destroy(backend);
  } else {
      // Backend threads still read the registry, so it stays
      // allocated until the process exits.
      debug_trace.logf("terminal_client",
          "terminal backend left allocated: threads still draining", .{});
  }
  ```

- 触发：`closeOwnedTerminals` 判定 `backend_drained == false`（有子进程仍持 PTY、输出线程未在宽限内结束）。
- 后果：`ProfileStore`、`Registry`（含会话记录与映射表）与 `Backend` 本体永久驻留；`self.backend = null` 后连指针都丢失，**无法再回收**。这直接对应「空闲后 WS/Private 不下降」，属**设计性不归还**，非持续增长。
- 修复：保留 `backend` 指针做延迟回收（drain 完成时再 free），或在 `retire` 表中登记以便后续复检。

### 16.5 P3：HTTP 连接池在 warm 飞行中放弃释放

- 证据：`src/core/shared/http_pool.zig:54-69`、`:140-153`；调用方 `src/core/app/provider_runtime.zig:36-43`、`src/core/cli/cli_ask.zig:1555-1558`。warm 未完成时返回 `.abandoned_warm_flight` 且**不 `client.deinit()`**；`pool.deinit()` 非 `.destroyed` 时 pool 本身也不释放。
- 触发：warm 线程仍在 `connect` 中（启动后 500ms 内退出，或 TLS 握手阻塞）。
- 后果：`std.http.Client` 的 CA bundle、连接池与未关闭 fd 全部泄漏；单进程仅一次，量级有限但确定性。
- 修复：warm 线程改为可 join（用 Event 替代 500ms 轮询），或把 `client` 转交给 warm 线程负责释放。

### 16.6 P2：shell snapshot 持锁 join 采集线程，存在互等风险

- 证据：`src/core/terminal/shell_snapshot.zig:536-541`。`startCaptureLocked` 在持 `mutex` 时 `thread.join()`，而被 join 的线程收尾需同一把 `mutex`（`:563`、`:443`）。
- 后果：当前靠「`state != .capturing` 时线程一定已释放锁」的时序假设成立，属**脆弱不变式**；一旦打破即死锁，终端功能整体挂起。
- 修复：join 前释放锁（把 `capture_thread` 取出到局部变量，解锁后 join）。

### 16.7 P2：MCP runtime 用无超时自旋等待在途请求

- 证据：`src/core/mcp_host/runtime.zig:513-521`：`if (r.thread) |t| t.join();` 然后 `while (r.active.load(.acquire) != 0) std.Io.sleep(..., 1ms, ...)`。
- 触发：某次工具调用卡在无 deadline 的 server 上时重载配置或退出。
- 后果：`deinit` 永不完成，`arena`/`snapshot_arena`/`queue`/`calls` 全部滞留；外层 `Host.stop` 是 detached 线程，表现为「线程与内存都不归还」，叠加线程数不下降。
- 修复：给等待加截止时间，超时后标为 abandoned 交 `waitRetired` 统一收尾。

### 16.8 P3：ACP 启动 prompt 失败时 steering 已 open，留下可累积队列

- 证据：`src/acp/server.zig:2413-2422`。`session.steering.open(...)` 先执行，随后 `std.Thread.spawn` 失败时 errdefer 只释放 `active`/`msg`。
- 后果：`accepting = true` 但无 turn 消费，之后每条 steer 进 `messages`（受 `max_messages`/`max_queued_bytes` 约束），直到下次 `open` 才 `clearLocked`；有界但非预期，且客户端收到「已接收」。
- 修复：spawn 失败路径补 `session.steering.close(...)`。

### 16.9 该域已确认有界或无泄漏（可信结论）

`shared/select_watch.zig` 的 `Watch.run/finish` 无取消竞态泄漏；`terminal/client.zig` 队列（`queue_capacity=16`、`outcome_capacity=32`、`max_active_requests=32`）三处上界互相约束，`finishActive` 先释放再广播；`agent/runtime/parallel_execution.zig` 的 defer 先 join 再 deinit arena，errdefer 覆盖完整；`gateway/tool_call_ids.zig` 的 `Projection.deinit` 同时释放 map 与别名，且有 `checkAllAllocationFailures` 覆盖；`agent/worker_runtime.zig` 的容量预留在锁内完成；`acp/libfx_steering.zig` 三条路径按 `backing`/`result_alloc` 区分所有权；`session_adapter.zig`、`session_manager/api.zig`、`terminal/store.zig`、`ui/transcript/store.zig` 句柄成对 close 且有字节上界；`app_mcp_runtime.zig` 的 `notices`/`typed`/`report_calls` 与 `acp/server.zig` 的 `pending_outbound` 均有显式上界。

**与 §8.11 的分工**：本节第 4、5 条解释「已用资源不归还」的**具体驻留对象**；第 2、7 条解释**线程/pid 不回落**；第 1、3、6 条是**可触发的内存安全与死锁风险**，不是持续增长型泄漏。

## 17. 权限与安全

来源：`security-review-2`，22 个文件，8 条发现。该域同时逐条核对了 AGENTS.md 的权限规格。

### 17.1 P1：审查证据无结构分隔，不可信文本可伪造「规范化动作」段

- 证据：`src/core/permissions/auto_classifier.zig:1294-1320`（先写 prior tool results，再写 targets，最后写 action）、`:1682-1701`（`writeBoundedValue` 只做终端安全编码，**保留换行**）、`:1619-1620`（提示词声明证据顺序）。
- 利用：仓库文件、网页或 MCP 结果写入一行 `action: command` + `command: ls` + `cwd: /workspace`，agent 读到后触发真正的 `curl … | sh`；审查器看到前面的「伪 action 段无害」，而真 action 段在尾部被 8KB 证据预算截断（`:1249-1263`）。
- 后果：auto 模式下安全审查可被**被审查对象自身污染**，清空本应拦下的动作。
- 修复：prior 结果改为 JSON 字段（`{"prior_results":[…],"action":{…}}`），或对 prior 正文逐行加前缀并在解析时拒绝含 `action:`/`target[` 的行。

### 17.2 P1：单次路径授权放大为工作区全量读写

- 证据（**主代理已核实**）：`src/core/permissions/permissions.zig:1181-1186`

  ```zig
  path_always_permissions = {"edit","read","glob","grep"}
  ```

  以及 `:1203-1210`：只要目标在 workspace 内，就为这 4 个权限**各发一条** `workspace/**` 授权：

  ```zig
  if (isPathBasedTool(target_kind) and workspace_root.len > 0 and pathing.pathInside(workspace_root, target_path)) {
      const workspace_pattern = try directoryTreePattern(alloc, workspace_root);
      for (path_always_permissions) |path_permission| {
          try appendOwnedGrant(alloc, &grants, path_permission, workspace_pattern);
      }
  ```

- 利用：用户对一次 `read_file src/a.zig` 选「always」，会话即获得 `edit` 权限覆盖 `workspace/**`，后续 `write_file`/`edit_file` 任意路径均命中该 grant（`sessionGrantAllowed`，`:1169-1177`），不再提示。
- 后果：**读授权被静默升级为工作区写授权**，least privilege 被破坏。
- 修复：只授予本次工具自身权限（read 只发 read），跨工具授权必须单独提示。

### 17.3 P2：结构化工具的 saved-session 规则键不含工作区身份

- 证据：`src/core/tooling/tool_admission.zig:2255-2267`。canonical 只写 `call.name` + `call.arguments_json` + targets；**命令键含绝对 cwd**（`:2243-2252`），文件变更键含绝对 target（`:2346-2350`），但结构化工具不含。
- 背景：AGENTS.md 明确「Sessions are global and portable across workspaces」，恢复后 `workspace_root` 会变更。
- 利用：在工作区 A 对 `read_file {"path":"notes.md"}` 记住 allow，同一 session 在 B 打开时同名相对路径命中同一 key，直接放行。
- 修复：把 `workspace_root`（或解析后的绝对目标）纳入 canonical 字节。

### 17.4 P2：auto 模式无审查执行仓库自带脚本

- 证据：`src/core/shell_command/command_effect.zig:250-274`（`npm install|i|ci|test`、`... run <任意脚本>`，仅排除 global 标志）、`:129-131`（`zig build` 及任意构建参数），被 `src/core/tooling/tool_admission.zig:1126-1147` 判为 `auto_mode` 直接执行。
- 利用：克隆陌生仓库并让 agent「装依赖/跑测试」，`package.json` 的 postinstall 或 `build.zig` 在无审查、无提示下以用户身份执行任意命令；`npm run <name>` 无脚本白名单。
- 后果：供应链 RCE 落在唯一被信任的免审查通道上。
- 修复：`npm install` 强制 `--ignore-scripts`（或脚本执行走审查），`run` 限定脚本白名单，`zig build` 首次执行走审查。

### 17.5 P2：`ls` 直接计划接受任意绝对路径

- 证据：`src/core/shell_command/command_effect.zig:748-799`（operands 原样追加在 `--` 后，无 scope 解析）；`src/core/tooling/tool_admission.zig:1101-1107` 对 `direct_only` 提前返回，不再评估访问范围，**`ask` 模式同样不提示**。
- 利用：`ls -la /home/user/.ssh`、`ls /etc`、`ls ../../..` 在 ask/auto 下均无提示执行，输出目录名、大小、权限位。
- 修复：解析 operand 并要求落在 `AccessScope` 内；绝对路径或含 `..` 的 operand 转审查。

### 17.6 P2：normal 视图的 caution 校验缺少「用户原文」排除

- 证据：`auto_classifier.zig:448-452`（仅 contextual 视图传 `trusted_root_context`）、`:833`（`sourceContains(trusted_root_context, …)`，空串直接 false）、`:1455-1461`（file_mutation 与非 schema 工具走 normal）。
- 后果：规格要求「引用出现在用户自己的请求中时应清除」，normal 视图下该比较**恒不生效**，导致误 hold（用户原话含某句时无法清除），判定口径也不一致。
- 修复：normal 视图同样传入并校验 bounded root context，或对 file_mutation 一律用 contextual 视图。

### 17.7 P3：`safe_git` 的 prepare→exec TOCTOU

- 证据：`src/core/shell_command/safe_git.zig:56-73`（读一次 repo config，`filters.names` 固化）、`:112-117`（只对这批名字追加 `-c filter.<name>.*=`）。
- 利用：`prepare` 与 spawn 之间另一进程（或刚写出的 `.git/config`）新增 `filter.evil.process` 并让 `git diff` 命中该属性；hooks/fsmonitor 已被 `-c` 关闭，但**新 filter 未被置空**。
- 修复：执行前重读 config 并比对，不一致则 fail closed；或用固定 `filter.*` 全禁策略。

### 17.8 P3：MCP 动态工具的权限目标只有工具名

- 证据：`src/core/tooling/tool_admission.zig:2555-2558`：动态工具 target 固定为 `call.name`；对比 `run_command` 的 target 为 `cwd::command`（`:2599-2613`）。
- 后果：对 `mcp_github_create_issue` 选 always 后，该工具任意参数调用全部命中同一 target；配置侧无法写「仅允许某仓库」的 deny/allow。MCP 授权粒度与命令侧不一致。
- 修复：target 纳入参数的有界哈希（或 schema 声明的关键字段），并让配置规则可引用。

### 17.9 该域已确认符合规格

auto/ask/full-access 三模式与 yolo 提前返回（`tool_admission.zig:1368-1376`）；configured deny 先于 session grant 与 session state（`:1388-1423`）；review 仅两类 harm 且 caution 必须带 category+evidence（`auto_classifier.zig:764-838`）；fresh review 解禁（`:686-712`）；turn 级 review budget 与 unavailable 不缓存为判断（`agent/runtime/tool_admission.zig:66-125`）；transport 失败重试一次、malformed 重试一次（`:583-678`）；legacy `permission_request_id` 拒绝（`ask_user_question.zig:87-98`）；`review_feedback` 结果排除出后续证据（`:214-217`）；`safe_git` 关闭 fsmonitor/hooks/signature/filter 并校验同仓库（`safe_git.zig:100-118,205-221`）；auto 模式 unsafe_git 返回给 agent 而不执行（`tool_admission.zig:2138-2148`）；日志仅记录字节数与错误名，未发现凭据落盘（`responses_permission_reviewer.zig:267-324`）。

### 17.10 该域未覆盖

`src/core/mcp_host/` 其余文件、`src/mcp/` 传输层、`approval_amendment.zig`/`permission_gate.zig` 未逐行阅读。

## 18. 修复台账（按优先级，待逐项实施）

全部 14 个域已收口。按「先止血、再修正确性、最后做优化」排序。

> **实施约定（强制）**
>
> 1. **先修完，再构建。** 把所有要改的点一次性改到位，构建次数控制在 **2~3 次**以内：一次用于确认全部改动能编译，一次用于修完编译错误后的验证，最后一次用于 `./zig-out/bin/fx` 实机跑。**禁止每改一个文件就 `zig build` 一次。**
> 2. **修一项，勾一项。** 本表每项前置 `[ ]`，修完并验证后改成 `[x]`，同时在对应章节的标题后追加 `（已修复）`。未勾掉的项目不得重做或重复排查。
> 3. **代码、注释、文档三者对齐。** 改动处若含注释（尤其是解释「为什么这样设计」的注释），必须同步更新；`AGENTS.md`、本报告对应章节、`--help` 文案若受影响，同一次改动内一起改完。**不允许留下注释说 A、代码做 B 的情况。**
> 4. 每项完成后用 `git status` 确认没有夹带无关改动。

### 18.1 第一批：止血（P0，直接对应本次实测故障）

- [x] **1. 代码层硬禁二级子代理**：`starts_subagents` 改为「有 host **且深度 < 1**」，`keepTool` 对一级无条件剔除 `subagent`，并同步改写 `authority.zig:612-620,693-696` 的两处注释
  位置：`src/core/app/app_agent_runtime.zig:1211-1215`、`src/core/subagent/agent_adapter.zig:436-437`、`authority.zig:693-699`
  验证：深度 0/1 边界单测；`index.jsonl` 不再出现 depth ≥ 2
  落地：`authority.keepTool` 一律拒绝 `subagent`，并新增 `max_subagent_depth = 1` 常量；`tool_host.executeManaged` 对非 root 调用返回 `subagent_nested_forbidden`；`agent_adapter.startsSubagents(role)` 让 ACP 与 `fx ask` 的子代理 schema 也拿掉该工具；`system_prompt.md` 与 `subagent_role` 段分别向主代理和子代理声明身份与禁止嵌套。
- [x] **2. `subagent_max_children` 设置项（1–16，默认 4）**，按 §10.10 的 7 处接线；`subagent_max_depth` 固定为 1 不暴露
  位置：`settings_keys.zig`、`config_runtime.zig`、`settings_store.zig`、`env_settings.zig`、`agent_steps.zig`、`app_lifecycle.zig`、`cli_config.zig`
  验证：`cli_config.zig` 的强制归类测试已覆盖新 key（`resolved_keys`）；配置优先级经 `applyEnvSettingOverrides` 与 settings 合并路径统一
  落地：`settings_keys` 声明 `.profile`/`integer`/1–16；`config_runtime.Settings` 与 `parseProjectSafeFields` 解析；`settings_store` 写入与校验；`env_settings` 映射 `FX_SUBAGENT_MAX_CHILDREN`；`agent_steps` 提供解析与 clamp；`app_lifecycle` 两处生效；`cli_config` 的 `Writable`/`resolved_keys`/`effectiveValue` 接线。`tool_host.max_children` 由交互应用、ACP、`fx ask` 三处注入。
- [x] **3. `Owner.start` 加 permit；`parallel_execution.zig` 加 `max_parallel_subagent_calls`**（参照同文件 `max_parallel_host_calls = 16`）
  位置：`managed_owner.zig:264-275`、`parallel_execution.zig:48-52`
  验证：permit 耗尽返回可操作错误；分组被截断
- [x] **4. 消除 1ms 忙轮询**：把 1ms 限制在真正等待的短窗口，`poll=0` 分支加最小间隔
  位置：`src/main.zig:216-225`、`src/ui/event_loop.zig:91-95`
  验证：活跃期 CPU 采样对比；`focused_ui_worker_poll_timeout_ms` 1→4，`poll=0` 分支改为 2ms 最小间隔
- [x] **5. `default_max_agent_steps` 改为有限值**；nudge/continuation 加独立预算
  位置：`src/core/config/agent_steps.zig:3,23-25`
  验证：空回复连续场景不再无限消耗 API
- [x] **6. Release 等 CI gate**；marker 校验前移；artifacts 完整性断言
  位置：`.github/workflows/release.yml:3-5,309-351,362-381`
  验证：actionlint + dry-run；发布前必须四个必备 check 在同一 commit 上 success/skipped

### 18.2 第二批：安全与正确性（P1）

- [x] **7. 审查证据改结构化分隔**，阻断伪 `action:` 段
  位置：`src/core/permissions/auto_classifier.zig:1294-1320,1619-1620,1682-1701`
  验证：`writeUntrustedField`/`writeUntrustedLines` 给不可信证据的每一行加 `  | ` 缩进，伪造的 `action:` 行不再落在左栏
- [x] **8. 路径 `always` 只授予本工具权限**，不放大到 `workspace/**` 四权限
  位置：`src/core/permissions/permissions.zig:1181-1186,1203-1210`
  验证：`suggestedSessionGrants` 只发本工具权限；`read` 授权后 `write_file` 仍需提示
- [ ] **9. transcript 与工具输出过滤 ESC**（保留 SGR，丢弃其余 C0/CSI/OSC）
  位置：`src/core/shared/text_utils.zig:19-22,560-563`、transcript 渲染
  验证：`cat` 含 `\x1b[2J` 的文件后屏幕不被清
- [ ] **10. Anthropic 路径补 JSON 深度检查**
  位置：`src/gateway/anthropic_messages.zig:416-424,604-608`
  验证：深 300 层 input 返回可恢复错误而非 abort
- [ ] **11. 退出超时后不销毁 MCP sink**，改 retired + 引用计数
  位置：`src/core/app/app_mcp_runtime.zig:379-395`
  验证：慢 MCP 场景退出不崩溃
- [ ] **12. 修正 shell 工具描述与 schema 冲突**
  位置：`src/builtins/tools.zig:80-81,97-105,118`
  验证：Windows 按描述切 Git Bash 不再整轮失败
- [ ] **13. 收窄 validation 判重 digest、提高 budget、notice 加可操作恢复信息**
  位置：`tool_admission.zig:205-235`、`orchestrator.zig:155-156,12007-12027`
  验证：复现两个报废子代理场景
- [ ] **14. `pacer.consume` 改读偏移**替代 `@memmove`
  位置：`src/ui/assistant/pacer.zig:425-431`
  验证：长回答时 CPU 与分配对比
- [ ] **15. `unescapeCarried` 精确匹配语义**
  位置：`src/core/tooling/file_mutation.zig:1478-1486`
  验证：含 `&lt;fx-skill-used>` 的文档往返测试
- [ ] **16. 路径工具 active scope 纳入准入**
  位置：`src/core/permissions/`、`src/core/workspace/`
  验证：`--no-additional-dirs` / 符号链接回归
- [ ] **17. `node.js` fetch 清理修 drain 死分支 + `fetchState` 改 Map**
  位置：`sdk/node.js:405-456,520-543`
  验证：并发 fetch + 取消不泄漏
- [ ] **18. WASM HTTP 流统一 `closeStream`**
  位置：`sdk/wasm-runtime.js:310-338,929-932`
  验证：多轮流后 `streams` 不增长

### 18.3 第三批：资源与平台（P1/P2）

- [ ] **19. terminal backend 延迟回收**（不再「留到进程退出」）
  位置：`src/core/terminal/client.zig:466-479`
  验证：关闭终端后 WS 回落
- [ ] **20. 终端启动失败路径 `kill` 后 `wait`**
  位置：`src/core/terminal/native_session.zig:441-457,1728-1830`
  验证：失败路径不留 zombie
- [ ] **21. ticker 持锁不做 I/O**
  位置：`src/core/agent/runtime/request_recovery.zig:406-423`
  验证：宿主阻塞时 `endSend` 不被拖住
- [ ] **22. `shell_snapshot` join 前释放锁**
  位置：`src/core/terminal/shell_snapshot.zig:536-541`
  验证：连续采集不死锁
- [ ] **23. MCP runtime 等待加截止时间**
  位置：`src/core/mcp_host/runtime.zig:513-521`
  验证：卡住时 deinit 能完成
- [ ] **24. Windows `zig build` 覆盖运行中 exe**
  位置：`build.zig:94`、`upgrade_helpers.zig:391-425`
  验证：Windows CI 增加占用用例
- [ ] **25. `detect-macos-need.sh` 把平台分支改动一律视为需 macOS**
  位置：`scripts/detect-macos-need.sh:52,96-97`
  验证：Windows-only diff 触发 macOS
- [ ] **26. SSE 设 `max_total_bytes`**；`StreamTooLarge` 与 `EventTooLarge` 分开
  位置：`src/gateway/sse.zig:93-99`、`chat_completions_protocol.zig:1015-1020`
  验证：注释行攻击不再无限流
- [ ] **27. Anthropic `input` 加字节上限并校验**
  位置：`anthropic_messages.zig:365,494-501`
  验证：畸形参数被拒

### 18.4 第四批：体验与契约（P2/P3）

- [ ] **28. 统一 CLI `UsageProblem` snapshot**；`--help` 不再绕过校验
  位置：`src/core/cli/`、`output_contracts.zig`
  验证：`cli.test.ts` 负例矩阵
- [ ] **29. 正常退出补 `\x1b[?7h`**
  位置：`src/core/app/app_lifecycle.zig:48`
  验证：退出后长行不串行
- [ ] **30. 审批屏紧凑布局保留文件名与按键提示**
  位置：`src/ui/approval_screen.zig:285-293,690-704`
  验证：6 行终端可读
- [ ] **31. 审批屏 layout 缓存**，避免每帧重建
  位置：`src/ui/approval_screen.zig:317-322`
  验证：5 万行滚动不卡
- [ ] **32. Windows resize 轮询降到 100–200ms**
  位置：`src/ui/resize_runtime.zig:28-45,271-284`、`main.zig:187-188`
  验证：空闲 CPU 下降
- [ ] **33. `catalog_menu` 接线或删除**
  位置：`src/ui/shell_runtime.zig:67-72`
  验证：文档与实现一致
- [ ] **34. CRLF / 无末尾换行标记**；result_store 统一截断标记
  位置：`read_file.zig`、`execution_memory.zig`
  验证：往返测试
- [ ] **35. detector / fuzz registry / smoke / shellcheck 覆盖补齐**
  位置：`scripts/`、`tests/fuzz/targets.json`
  验证：对应 CI job
- [ ] **35b. 从版本控制移除 `__pycache__/*.pyc`**（本次实测：`scripts/__pycache__/` 与 `scripts/pgso/__pycache__/` 共 8 个 `.pyc` 被 `27122c20` 提交进仓库；子代理运行 Python 检查后它们在工作区被删除，`git status` 出现 8 条 `D`）。`AGENTS.md` 明确禁止提交生成状态
  位置：`.gitignore`、`scripts/__pycache__/`、`scripts/pgso/__pycache__/`
  验证：`git status` 干净；`git ls-files '*__pycache__*'` 为空
- [ ] **36. macOS E2E `FX_SOUND=0`**、`ci.yml` permissions、action SHA pin、`cdn-backfill` env 传参
  位置：`.github/workflows/`
  验证：actionlint + shellcheck

### 18.5 构建与验证批次（严格 3 次构建）

| 批次 | 内容 | 构建次数 |
| --- | --- | --- |
| A | 一次性完成第 1–18 项全部代码改动 | 1 次 `zig build`（确认可编译） |
| B | 修完 A 暴露的编译错误与注释不一致 | 1 次 `zig build`（确认干净） |
| C | 跑 `zig build test` 的针对性用例 + `./zig-out/bin/fx` 实机驱动 | 1 次 `zig build` + 实机 |
- 第 19–36 项（资源/平台/体验）在同一批次内一起改，不单独触发构建。
- **禁止**在 A、B、C 之间插入「改一个文件就 build 一次」的循环。
- 若 C 阶段发现问题，集中在下一轮 A 里一起改，不要零散重试。

### 18.6 用户追加的缺陷（2026-11-06 使用中反馈）

- [ ] **37. Provider 刷新出来的模型，思考层级只有 Default、无法选择**
  位置：`src/core/config/model_capabilities.zig`（能力解析）、`src/core/gateway/model_catalog.zig` 与 `src/core/mcp/model_catalog.zig`（模型目录）、`src/core/config/configured_provider.zig`（自定义 provider）、思考层级在 UI 与 `/model` 选择器中的渲染。
  现象：通过 provider 的模型刷新接口拿到的模型，在设置里思考程度（effort / thinking）只有 Default，改不了也换不了。
  期望：思考层级应当跟随模型一起从 provider 获取，并且按 provider、按模型各不相同——不同 provider、不同模型的层级名称和档位都不一样，不能统一成一套硬编码枚举。
  参考实现：`D:\Projects\pi-rust`。它同样在拉取模型时一并取用对应的 thinking 层级，并用 thinking 命令配置层级，可以直接对照抄它的数据来源与命令接线。
  验收：给一个声明了多档思考层级的 provider 与模型，设置里能列出它自己那几档并选中生效；换一个 provider 不会串档；没声明的模型仍回落 Default。

## 19. 修复前必须要做的三件事

1. **内存归因实测**（约 10 分钟，决定第 19–23 项是否值得做）：VMMap 按 `Heap` / `Stack` / `Mapped File` / `Private Data` 分类，对比「代理运行中」「全部停止后 1 分钟」「停止后 10 分钟」三个时点。
2. **确认设置项面板**：`subagent_max_children`（1–16，默认 4）需在 `fx config` 中可见可改；`subagent_max_depth` 固定为 1、不暴露给用户（理由见 §10.9）。
3. **确认构建批次**：按 §18.5，全部代码改动一次做完，构建控制在 3 次以内。

## 20. 子代理数量治理：定案总结

这一节是本次审查最重要的产品结论，单独成节以便直接引用。

### 20.1 问题

实测单进程产生了 **231 个会话、8 层嵌套**，其中单个一级子代理带出 11 个下级。结果是线程峰值 312、进程 Private 约 11.6 GB、空闲时不归还。根因不是「用户开太多」，而是**代码层没有任何深度或数量上限**：`subagent` 工具默认被继承（`authority.zig:693-699`），`starts_subagents` 恒为真（`app_agent_runtime.zig:1211-1215`），`Owner.start` 无 permit（`managed_owner.zig:264-275`），并行 subagent 前缀无上限（`parallel_execution.zig:48-52`）。

### 20.2 定案

维持「**1 个主代理 + 少量一级子代理**」的工作模式：

| 维度 | 定案 | 是否用户可配 |
| --- | --- | --- |
| 一级子代理数量 | 由用户设置，范围 1–16，默认 4 | 是（`subagent_max_children`） |
| 嵌套深度 | **硬固定为 1，禁止二级** | **否，代码写死** |
| 独立代理 | 不提供开启入口 | 否 |

### 20.3 为什么深度不做成可配项

- 有限资源配不上无限嵌套。任何 N 层配置都只是把爆炸推迟到下一层。
- 本次事故的直接成因就是「可无限派生」，把它做成可配项等于保留同样的隐患，只是默认值更小。
- 用户明确要求「不允许去开独立代理」，因此不提供开启入口。

### 20.4 预期效果

从实测的 231 个会话收敛到 **1 + 4 = 5 个会话**；线程数、上下文复制量、token 消耗随之从 `O(N×上下文)` 降到有界常数。这与 §8 的复杂度分析一致：只有加并发上限，复杂度才能从 `O(N*上下文长度)` 降到 `O(1) + O(min(N, cap))`。

### 20.5 配套必须一起改的地方

单改深度判定不够，还必须同时收敛可见性与线程准入，否则「广告了但拒绝」仍会浪费轮次，子代理也仍会各自起线程：

1. 深度判定参与 `starts_subagents`（不可见即不会被调用）。
2. `authority.zig` 的 `keepTool` 对一级无条件剔除 `subagent`。
3. `Owner.start` 加 permit，`parallel_execution` 加分组上限。
4. 两处注释（`authority.zig:612-620`、`:693-696`）必须同步改写，否则与新行为矛盾。

### 20.6 子代理完成一项就要勾掉

为避免重复劳动，执行时严格按 §18 的 `[ ]` → `[x]` 推进：

- 每完成一项：勾掉该项，并在对应章节标题后加 `（已修复）`。
- 同一项涉及代码、注释、文档时，**三者必须一起改完才算完成**。
- 勾掉的项目不再回头复查；只有集体验证阶段（§18.5 的 C 批）发现问题时才重新打开。


 index.jsonl 里共有 231 个会话，嵌套深度多达 8 层：

  ┌─────────────┬────────┐
  │ 深度        │ 会话数 │
  ├─────────────┼────────┤
  │ 0（主会话） │ 51     │
  ├─────────────┼────────┤
  │ 1（子代理） │ 63     │
  ├─────────────┼────────┤
  │ 2（孙代理） │ 37     │
  ├─────────────┼────────┤
  │ 3           │ 41     │
  ├─────────────┼────────┤
  │ 4           │ 23     │
  ├─────────────┼────────┤
  │ 5           │ 5      │
  ├─────────────┼────────┤
  │ 6           │ 3      │
  ├─────────────┼────────┤
  │ 7           │ 8      │

  想想就恐怖

D:\Projects\pi-rust 提醒，这个也是参考，也可以参考的。它在使用的时候也是可以去获取那个模型，然后也可以
 去使用对应的thinking命令去配置这个思考层级的。你也可以提醒写在台账里面，只要到时候让他照着参考去抄去用
 。
 ，对了，就是还有一个bug提醒你要修，你有，或者写到文档里面去，后续修也行。就是说是通过那个获取模型获取
 过来的那些模型吧，Provider刷新接口获取的模型，在设置里面，这个模型它的思考程度只有Default，没有办法选。
 按道理来说，这个思考程度应该也可以通过获取模型一起获取过来的。但是现在只有Default，动也动不了，选也选不
 了，换也换不了。而且不同的Provider不同的模型，它那个思考的层级和选项是不一样的，这还不能统一，还不能乱
 搞。
