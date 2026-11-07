# fx 内存审计总报告（2026-11-07）

本轮为专项内存审计：内存泄漏、悬垂指针 / use-after-free、double-free、未释放内存、大量占用、内存节省与可优化点。6 个子代理分域静态审查（纯读码 + grep，未跑构建 / 测试 / 二进制），主代理对每份报告的重点发现逐条复核了代码原文。分报告：

| 域 | 文件 | 发现 |
| --- | --- | --- |
| 1 agent runtime | `_mem_01_agent_runtime.md` | P0=0 P1=0 P2=4 P3=3 疑似=2 |
| 2 session/持久化 | `_mem_02_session_persistence.md` | P0=0 P1=0 P2=3 P3=3 疑似=3 |
| 3 UI/terminal | `_mem_03_ui_terminal.md` | P0=0 P1=1 P2=4 P3=1 疑似=4 |
| 4 gateway/MCP/tools | `_mem_04_gateway_mcp_tools.md` | P0=0 P1=1 P2=4 P3=1 疑似=5 |
| 5 跨模块效率 | `_mem_05_efficiency_savings.md` | S1–S16（无泄漏，纯节省） |
| 6 错误路径/UAF | `_mem_06_error_paths_uaf.md` | P0=0 P1=0 P2=2 P3=6 疑似=5 |

**总计数：P0 = 0，P1 = 2，P2 = 17，P3 = 14，疑似未证实 = 19。**

## 1. 结论总览

1. **没有证实的实时内存泄漏、没有证实的悬垂 / UAF / double-free。** 6 个域、约 17 万行代码静态扫描，分配与释放配对总体规范：errdefer 链在热点路径（`main.zig:1725-1815` 的 15 步 dupe 链、`managed_owner.zig:288-307` 的 slot 创建链）完整；arena 统一 `defer deinit`；`parallel_execution.zig:230-243` 先 join 再 deinit；图片 / 凭据 / 工具结果均有成对 free 且凭据用 `zeroAndFree`。
2. **内存「省不省」的主要矛盾不是分配器，而是生命周期与拷贝策略。** 最大浪费集中在三处：每 turn 全量历史深拷贝（S1）、SSE 流双份保留（M-01）、diff_entries 全寿命双表示（S2）。修复收益按量级排序见 §4。
3. **上一轮（2026-11-06）§8 的「高提交 ≠ 泄漏」结论维持不变**：6.8 GB Private / 1.5 GB WS 的形态是「线程栈提交 + CRT 堆高水位 + arena 高水位」，非单调泄漏；本轮未发现能推翻它的新证据。
4. **上一轮 §8 的 P0 三项中一项已修复、两项未修**（见 §3 的基线对照）。

## 2. 经主代理复核确认的 P1（建议优先修）

### P1-1：SSE 流期间文本双份无界保留（04 号 M-01，已复核代码原文）

- 位置：`src/gateway/client.zig:4478`（`if (content_capture_limit == null) try replay.observe(root, content_buf.items.len, separated)`）、`:4371` `content_buf`、`:4447` `event_arena.reset(.retain_capacity)`。
- 机制：生产默认 `content_capture_limit = null` 时，`capturedText` 返回全文，`content_buf` 无限增长；同一条件下 `replay.observe` 又把全部事件存进 `GatewayReplayBuilder`。文本每字节在流期间被保留两份。`event_arena` 用 `retain_capacity`，单事件 JSON 树高水位在流结束前不归还（`max_sse_event_line_bytes = 32 MiB`，`client.zig:227`）。
- 调用面证据：主模型请求路径全部传 `null`——`gateway_step.zig:212/498/557/621`、`orchestrator.zig:7930`、`stream_provider.zig:784/895`、`builtins/gateway.zig:393`；只有 cache warmer / 标题生成传了上限（`cache_warmer.zig:310`）。
- 修法：replay 改为引用 `content_buf` 的区间（offset+len）而非再存一份；给 replay 设与 capture 同一上限；流结束后对 `event_arena` 做一次 `reset(.free_all)` 或按高水位阈值收缩。
- 证实：对 `consumeSseStream` 加 1 MiB 文本流用例，分别统计 `content_buf` 与 replay 占用（现有 `:4925` 的 `arena.queryCapacity() <= output_bytes*4` 断言可改造）。

### P1-2：transcript window 开启后 entries 无字节上界（03 号 M03-01，已复核代码原文）

- 位置：`src/ui/transcript/runtime.zig:7203-7250`（`enableTranscriptWindow` / `syncTranscriptWindow`）+ `src/ui/transcript/store.zig:694-734`（`dropEntriesAtomic` / `dropEntries`）+ `transcript_window_shell.zig:104-116`（`sync`）。
- 机制：`enableTranscriptWindow` 的注释明示「the byte cap no longer applies，释放完全依赖 window sync 的 drops」。`Shell.sync` 只报告「finished 且不在屏上」的 entry；pinned（`lifecycle_pinned`，`store.zig:714-717`）、在屏、尚未 finish 的 entry 全部留下，且无条数上界。`dropEntries` 只删 window 报的 drops，pinned 永不删。长会话下 `notebook.entries`（每条自带 dupe 的 bytes / skill tokens / images，`store.zig:2194-2231`）随会话线性增长。
- 修法：给 window 模式的 entries 加条数 / 保留字节上界（如屏行数 × N），超限强制 drop 最老非 pinned entry；或让 `sync` 对超长前缀做整段 release。
- 证实：长会话（>10k 条 entry）采样 `notebook.entries.items.len` 与 `retainedStructuredBytes()`（`store.zig:180`）是否单调上升不回落。

## 3. 上一轮 §8 基线对照（修复状态）

| 上一轮条目 | 当时定级 | 当前状态 | 本轮证据 |
| --- | --- | --- | --- |
| §8.5-1 线程栈 16 MiB hint + `async_limit=.unlimited` | P0 | **未修**（且有语义约束） | `main.zig:4172` 仍 `.async_limit = .unlimited`，旁边注释说明：任务数达上限后 `io.async` 退化内联执行，会破坏 `HostName.connect` 的故障转移；`parallel_execution.zig:237` 仍 `std.Thread.spawn(.{})` 默认栈 |
| §8.5-2 子代理无并发上限 | P0 | **已修复** | `managed_owner.zig:141` `max_running = 4`，`start` 内 `running >= self.max_running` 返回 `error.TooManyChildren`（`:297`），许可门在 `:288-297`，errdefer 链完整 |
| §8.5-3 并行工具逐条起线程 | P0 | **部分修复** | `parallel_execution.zig:66,71` 有 `max_parallel_host_calls = 16` / `max_parallel_subagent_calls = 16` 组内上限，但每 call 仍默认栈 spawn，无跨组池化 |
| §8.6 root_user_messages 无条数上限 | P1 | **仍未加** | `child_state.zig:95` 字段无 cap；`agent_adapter.zig:335` 透传；`child_state.zig:122/154` cloneStrings 无条数检查 |
| §8.10-3 结束子代理的 arena 是否仍被引用 | 待证实 | **部分澄清** | `managed_owner.zig:620-628` `destroySlot` 释放链完整（join → 等 waiters → 断言 route_refs=0 → freeLeftovers → destroy）；但是否有别处引用子 arena 仍需 VMMap / 引用计数实测 |
| §8.11 空闲不退存 | 实测冻结 | **维持** | 性质为「已用过的内存不归还」，非持续泄漏；主因仍是 CRT 高水位 + 线程池不回收（169 条线程永久留池） |

## 4. 节省机会全景（按量级排序，详见各分报告）

| 排名 | ID | 位置 | 现状 → 建议 | 量级 |
| --- | --- | --- | --- | --- |
| 1 | S1 | `main.zig:1774`（+`:1871`、`:1764`） | `snapshotHistory` 每 turn 整段历史深拷贝 → 借用 + epoch 版本号 / 只投影 tail | 峰值 1–4 MB/turn，长会话 8–32 MB；N 并发子代理相乘 |
| 2 | M-01 | `client.zig:4478` | SSE replay 双份保留 → 引用 `content_buf` 区间 + 同一上限 | 主模型请求路径每 token 流峰值降近一半 |
| 3 | S8/M06 | `main.zig:4172` + `parallel_execution.zig:227` | 16 MiB 栈 hint + 逐 call spawn → 统一 2 MiB 小栈 + 池化 | 上界 308 × 16 MiB ≈ 4.8 GiB 提交（Windows hint，实际按需，需 VMMap 证实） |
| 4 | MEM-02-02 | `session_adapter.zig:3390-3396` | v1 家族转换 checked[] 全量驻留 → 两阶段校验 | K=20 × 5 MiB 时峰值 100 MB → 5 MB（20×） |
| 5 | S2 | `main.zig:2908` + `core/output/diff.zig:25` | diff_entries 全寿命持 full+preview → 默认 deferred + LRU | 500 次编辑 ≈ 25–90 MB 常驻 |
| 6 | M02/M09 | `tool_result_limits.zig:20-30` + `execution_memory.zig:948-956` | sanitize 双 pass → 先按 cap 取 prefix 再 sanitize，大结果走 handle | 每工具结果瞬时 3 份 → cap + 常数（默认 64 KiB cap 下每结果省约 2 份 ×64 KiB） |
| 7 | S3 | `main.zig:1725-1815` | 每 turn 12–15 次 dupe 链 → api_key/team/account_id/model 借用（需 generation 检查） | 每 turn 减少 4–8 次分配 + 拷贝 |
| 8 | MEM-02-01 | `session_manager/session.zig:507-508,786-787,1790-1791` | batch/bounds/bodies 只 clearRetainingCapacity → publish 后 shrinkAndFree | 最坏 ≈4 MiB/打开会话 × M 会话 |
| 9 | M03-01 | `transcript/runtime.zig:7203-7250` | entries 无上界 → 条数 / 字节上界 | 长会话线性增长（同 P1-2） |
| 10 | M03-03 | `frame_builder.zig:109-113` + `terminal_diff.zig:980-998` | 每帧 cell 缓冲双分配 + shadow 克隆 → 双缓冲复用 | 100×40 终端每帧约 100–200 KiB 瞬时分配 |

其余 P2/P3（M01、M03–M07、M-02–M-09、MEM-02-01/03/04/05/07、S4–S16、F-01–F-06）见各分报告，均带 file:line、量化、修法与证实方法。

## 5. 分配失败（OOM）路径测试覆盖

- 137 / 714 个 Zig 文件有 `FailingAllocator` / `checkAllAllocationFailures` 覆盖（约 19%），热点域（agent runtime、session、gateway、terminal、acp、permissions）已有。
- 零覆盖模块（按缺口排序）：`session_manager`（10 文件 0 覆盖，其中 `session.zig` 单文件 42 个分配点）、`core/output`（10 文件）、`core/hosts`（18 文件）、`core/gateway`、`core/cli`、`src/mcp`。
- 已确认的 OOM 泄漏：F-01 `worker_runtime.zig:4679-4689` `makePrompt` 连续 5 次 `try alloc.*` 无 errdefer（对比同文件 `makeImagePrompt` 有完整 errdefer 链，属疏漏）。修法：5 次分配改局部变量 + 统一 errdefer；验证：`checkAllAllocationFailures(testing_allocator.no_resize, makePrompt, .{...})`。
- 疑似 OOM 悬垂：F-02 `mcp/auth/client.zig:353-355` 与 F-03 `:472-479,758-765`——arena reset 后 `try dupe` 失败时字段仍指向旧 arena 内存（逻辑 UAF，非即时崩溃）。

## 6. 误报排除（读码后确认安全，不修）

- `request_recovery.zig` 持锁调宿主：上一轮 §16.3 的问题已在当前代码修复（`:406-423` 锁内只推进状态）。
- `parallel_execution.zig` 的 errdefer / defer 配对、`agent.zig`、`journal.zig`、`cache_warmer.zig`、`finalization.zig` / `interruption.zig`、`worker_runtime.zig:731-762` deinit、`tool_batch.zig` arena 所有权转移注释：逐行确认成对。
- `mcp/auth/client.zig` 的 `stepFlow(.failed)` 只置 `stage=.idle` 不重置 flow arena（M-02）：生命周期不对称但 arena 整体仍 deinit，非泄漏。
- `settings_store.zig` advisory lock + fingerprint 重试 + 随机临时名 + rename + 目录 sync、`session_codec` / `session_log` 的 v1/v2 双表示、skills catalog 代际引用计数、model_cache 单 catalog 替换、usage 缓存 arena 归 Owned、compactor summary 归 caller allocator、file_index 代际切换、help 32 KiB 栈上 FixedBufferAllocator：均合理。
- 悬垂 / UAF 高危模式（realloc 旧指针、HashMap value 失效、free 后使用、double free、闭包捕获）：本轮未发现确认实例，全部候选读码后为安全模式。

## 7. 需运行时证实（静态无法定论，按 §8.9 方法）

1. 栈提交真实占比：VMMap 按 Stack / Private Data / Heap / Mapped File 分类，对比「12 child 运行中 / 全部停止后 1 分钟 / 停止后 10 分钟」三时点。若 Stack 远低于 4.8 GiB，S8 收益估算需下调。
2. 线程池是否真的不回收：停止全部代理后连续 60 秒采样 Threads；若长期停在 169+ 确认池不回收。
3. CRT 堆高水位：同上三时点的 Heap 分类；提交不降而 live 对象已释放 → 确认高水位而非泄漏。
4. S1 / S2 / S3 的真实峰值：按 05 号报告 §4 方法（运行中采样 + 分配计数）。
5. M03-01 的 entries 增长：长会话采样 `notebook.entries.items.len` 与 `retainedStructuredBytes()`。

## 8. 修复优先级建议

1. **P1-1 / P1-2**（§2）：真实无界增长路径，修法明确，风险低。
2. **F-01**（§5）：确定性 OOM 泄漏，修法一行 errdefer 链，补 `checkAllAllocationFailures`。
3. **S1 + M-01**（§4 排名 1、2）：最大两项峰值节省；S1 需版本号防 compaction 改写，M-01 需 replay 引用化。
4. **S8 / M06**（线程栈与池化）：先跑 §7 的 VMMap 证实再定数字；但「有界并发 + 小栈」方向无论数字成立与否都应收敛（`async_limit` 的改动需同时解决 `HostName.connect` 故障转移语义）。
5. **P2 批量**：MEM-02-01/02、S2、S3、M02/M03 等，按各自报告的证实方法验证后修。

## 9. 审计方法与局限

- 方法：6 个子代理分域静态审查（grep 分配模式 → 读热点函数 → 追踪所有权 → 量化），主代理对全部 P1 / P0 候选与 Top P2 逐条复核代码原文。
- 局限：纯静态，未跑 `zig build` / `zig test` / 二进制，未做 VMMap / UMDH / 连续进程采样。所有「量级」为静态估算；§7 的实测项落地前，收益数字只能当排序依据。
- 基线：`docs/audit/2026-11-06-full-review.md` §8 / §9 / §16。本报告不重复其概述，只做验证与扩展。
- 本轮未修改任何 `src/` 文件；产出仅为 `docs/audit/_mem_0*.md` 与本文档。
