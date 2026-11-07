# 内存审计 05：跨模块内存效率与节省机会（静态审计）

- 范围：`src/main.zig`（组合根）、`src/core/app/**`、`src/builtins/**`、`src/core/shared/**`、`src/usage/**`、`src/core/modes/**`、`src/core/mods/**`、`src/core/compactor/**`、`src/core/agents/**`，以及全局/缓存类对象（model_cache、skills 缓存、file_index、auth session、provider 列表、compactor 状态）。
- 方法：grep 分配模式 → 读热点函数 → 追踪生命周期与容量决策 → 量化（字节数 × 频率 × 上界 × 可复用性）。纯静态阅读 + grep，未跑 `zig build`/`zig test`，未改任何文件。
- 基线：`docs/audit/2026-11-06-full-review.md` §8（多子代理并发内存）与 §16（泄漏类）。本报告只补 §8 未覆盖的跨模块效率面；§8 的 P0（线程栈/并发上限/parallel_execution 逐条起线程）不重复，只在 S8 做补充归因。

## 1. 摘要

静态确认的最大跨模块节省机会按量级排序：

1. **每 turn 整段历史深拷贝**（`src/main.zig:1774`，`snapshotHistory` 在 3 条入队路径各一次）：`max_history_turns=8`，每 turn 的文本/工具输出/图片附件全部 `dupe`。峰值 8–32 MB/turn 常见，且与 §8.6 的 per-child arena 峰值相乘。这是本域唯一同时影响主代理与全部子代理的放大项。
2. **`diff_entries` 全寿命双表示**（`src/main.zig:2908`、`src/core/output/diff.zig:25`）：`full.content`（完整 before/after，上限受工具结果 64 KiB × 2 约束）与 `preview`（≤24 KiB）同时驻留，进程退出才释放（`main.zig:1118-1120`）。长会话每轮编辑 +48–176 KiB，无上限。
3. **每步 12 份字符串拷贝链**（`src/main.zig:1725-1815`）：prompt/model/api_key/team/account_id/images/history/intent/grants/context/skill_bindings/spans 每 turn 各 dupe 一遍；其中 api_key/team/account_id/model 可借用（worker 在同 turn 内串行消费）。
4. **file_index 每代 `lower_buf` 与 `paths_buf` 等大**（`src/core/workspace/file_index.zig:238-241`）：上限 100,000 条 × 2,048 B，理论峰值 200 MB 副本。`lower_buf` 只服务 ASCII 精确匹配（`:1371-1386`），char_masks 已做快速拒绝。
5. **线程栈 16 MiB hint**（`src/main.zig:4172` `async_limit=.unlimited` + `parallel_execution.zig:227` 逐条 spawn）：§8 已记录；本报告确认代码面不变，仍是最大单一可降项（每线程 16 MiB → 2 MiB）。

已验证合理的域：skills catalog 代际 + 引用计数（零拷贝 adopt）、model_cache 单 catalog 替换、usage 缓存 arena 归 `Owned`、compactor summary 用 caller allocator、file_index 代际切换、help 32 KiB 栈上 FixedBufferAllocator、usage 固定 LabelBuffer 借用、mcp modes/mods 无常驻分配、启动期 MCP/技能均为异步加载。

总体判断：本域没有发现新的真实泄漏；浪费集中在**生命周期判断**（全寿命持有 vs 按需）与**拷贝链**（可借用 vs dupe），而非分配器本身。与 §8 的「资源不归还」不同，下面的项是「峰值与常驻可降」，修复后 Private 高水位会同步下降。

## 2. 节省机会表

量级均为静态估算；标「运行时证实」者未实测。

| ID | file:line | 现状 | 量化 | 建议 | 预期收益 | 风险 | 优先级 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | `src/main.zig:1774`（另 `:1871`、`:1764`） | `snapshotHistory` 每次入队都 dupe 全部 `HistoryTurn`（文本、tool output、图片路径/inline bytes） | `max_history_turns=8`（`src/core/agents/agent.zig:21`）；每 turn 工具结果可达 `max_tool_result_bytes`（默认 64 KiB）× 来回两条 + 用户文本；峰值约 1–4 MB/turn，长会话 8–32 MB；每 turn 一次，主代理+每子代理各一份 | 改为 worker 消费时借用：入队只传 `[]const HistoryTurn` + epoch/版本号，worker 在自己 turn 的 arena 内只投影需要的 tail；或 `dupe` 仅限最近一轮 + 已中断 turn（`recovery_checkpoint` 分支已是按需） | 每 turn 峰值降一个数量级；N 并发子代理时是乘法效应 | 中：worker 线程与主线程并发读 history，需版本号防 turn 中途被 compaction 改写；§8.6 已指出 `root_user_messages` 无条数上限，一并加 | P0 |
| S2 | `src/main.zig:2908` + `src/core/output/diff.zig:25,77` | `diff_entries` 同时持有 `full.content`（完整 before/after）与 `preview`（≤24 KiB，`max_encoded_preview_bytes`），进程退出才 `deinit`（`main.zig:1118-1120`） | 每 entry ≈ full（可达 2×64 KiB）+ preview（≤24 KiB）+ wrapped 副本（`wrapWithMarkers` 再 alloc，`:2921`）；长会话 500 次编辑 ≈ 25–90 MB 常驻，无上限 | 只留 `deferred`（content_handle + call_id），查看时 materialize；materialize 后再缓存且 LRU 上限（如 8 条）；`preview` 与 `full.content` 重叠部分共用一份 buffer | 常驻降一个数量级；长会话最明显 | 低：`fullDiffForMarker`/`hasFullDiffForLifecycle` 已走 deferred 路径，只需把新建 entry 默认改为 deferred | P1 |
| S3 | `src/main.zig:1725-1815` | 每 turn 12 次 `dupe`：prompt、model、api_key、gateway_team、account_id、images、history、intent_context、grants、context_snapshot、skill_bindings、skill_display_spans | 小串各 ≤128 B；images/history/grants 见 S1；合计每 turn 约 0.1–4 MB 纯拷贝 CPU + 瞬时峰值 | api_key/team/account_id/model 改借用（`QueuedPrompt` 生命周期覆盖 worker 消费，同 turn 内主线程不改 credential）；prompt 若 worker 立即消费可借用输入 buffer；其余保留 dupe 但合并到一次 alloc | 每 turn 减少 4–8 次分配 + 拷贝；降低 c_allocator 高水位抖动 | 低–中：需核对 `queuedPromptCredential()` 返回串的生命周期；credential 刷新时借用会悬垂，须加 generation 检查 | P1 |
| S4 | `src/core/workspace/file_index.zig:238-241` | 每代 `lower_buf` 与 `paths_buf` 等大；切换代时新旧两代并存（`active_generation` + `loading_generation`） | 上限 `max_indexed_files=100_000` × `max_path_len=2048` → 理论 200 MB/缓冲，切换瞬间 400 MB；实际受目录规模约束（万级文件 ≈ 每代 1–5 MB，可忽略） | `lower_buf` 只服务 `:1371-1386` 的 ASCII 精确匹配；改为匹配时按需小写化（`paths_buf` 上就地 fold 到栈上 scratch，`max_path_len=2048` 栈上足够），或仅在 `char_masks` 通过后对 `base_start..end` 段 fold | 大仓库每代省一份等大小缓冲；切换代瞬间峰值减半 | 低–中：`exactFit` 需确认只比较 ASCII 段；非 ASCII 路径已走 `scoreFoldedMatchWith` 分支（`:1386`），不受影响 | P2（大仓库才值得） |
| S5 | `src/core/app/app_render_runtime.zig:396-402` + `src/core/agent/worker_runtime.zig:2154` | 每帧 `buildSteeringProjection` 都 alloc messages + pending_feedback（每串 `dupe`），帧末 `deinit` | 每帧 2 个 ArrayList + N 条串 dupe；N 小（steering/feedback 队列有界，§16.9 确认），单帧字节小，但频率 = 帧率 | 仅在 `worker_events`/`queued_prompts` 版本号变化时重建；否则复用上一帧 buffer（clearRetainingCapacity） | 降分配频率而非峰值；减少 c_allocator 高水位抖动 | 低：需给 worker 状态加单调版本号 | P3 |
| S6 | `src/gateway/chat_completions.zig:112-157`、`src/gateway/anthropic_messages.zig:86-92,155-163` | 每 model step：`projectProviderReplay` 投影 + `Allocating` writer 整份 request body + 每工具 schema 单独 `Allocating` + `toOwnedSlice` | body 大小 ≈ context 长度（可达数 MB）；每 step 一次；N 并发子代理各一份 | request body 流式写 HTTP writer（`std.http.Client` 支持 writer 模式）；tool schema 按 name intern（`select_functions` 已注释「serialized once」，但仍在每请求 alloc）；投影消息借用 | 每 step 省一份 context 大小的瞬时副本；降峰值 | 中：流式 body 需 client 支持分块写；intern 表需线程安全（tool registry 已有锁） | P2 |
| S7 | `src/core/agent/runtime/orchestrator.zig:7157`、`src/core/session/session_adapter.zig:3812,4591,4599`、`src/core/session/session_log.zig:911,1113,1193,1214`、`src/core/session_manager/session.zig:1415,1854,1863,1896,2024,2077` | `reset(.retain_capacity)` 高水位只涨不缩 | 各 arena 上界不同；overlay arena 每 step reset（`:7157`），若某步触达峰值（如一次大工具结果），后续整 turn 都持该容量 | 对 >1 MiB 的 arena，turn 结束/空闲时 `reset(.free_all)` 或 `toOwnedSlice` 后重建；保留 <1 MiB 的 retain（避免抖动） | 降常驻高水位；§8.11 的「空闲不退」项之一 | 低–中：需确认 reset 后无悬空借用（overlay 生命周期已按 step 划分） | P2 |
| S8 | `src/main.zig:4172` + `$STD/Thread.zig` + `src/core/agent/runtime/parallel_execution.zig:227` | `async_limit=.unlimited`；`std.Thread.spawn(.{})` 默认 16 MiB 栈（Windows 只当 hint）；parallel 每工具调用再起一线程 | §8.2 已量化：上界 308 × 16 MiB ≈ 4.8 GiB 提交；实测栈提交占比未定（§8.10 待测项） | 统一小栈 spawn（2 MiB）+ `async_limit`/`concurrent_limit` 有界 + parallel 用共享池；本报告补充：`parallel_execution.zig:207-216` 的 slot arena 也可用池复用 | §8 已估 4.1 GiB（16→2 MiB）；池化再降 per-call arena 峰值 | 中：Windows 栈是 hint，实际提交按需；需 §8.9 的 VMMap 验证后再定数字 | P0（同 §8.5） |
| S9 | `src/main.zig:566-569` | `provider_selection`、`model_cache`、`usage_dashboard`、`lifecycle_runtime` 均以 `std.heap.c_allocator` 初始化并常驻 App | provider 列表 + model catalog 条目（`ModelCatalogEntry` 含 6 个 `[]u8` + ArrayList，`src/core/gateway/model_catalog.zig:325-346`）常驻；catalog 大小随 provider 数线性 | catalog 已按需加载（`LoadTrigger` 仅 activity/picker_open，`model_cache_runtime.zig:30-36`），保持；`usage_dashboard` 的 `entry` 仅在 `/usage` 时 build（`src/usage/usage.zig:284`），保持；不新增常驻 | 无新增（确认项） | 无 | —（已合理） |
| S10 | `src/main.zig:1084` + `src/core/app/model_cache_runtime.zig:753-786` | `model_cache` adopt 新 catalog 时 `freeModelCatalog` 旧 catalog + `menu.deinit`，单份常驻 | 条目数 × 每条 ~200 B；万级模型 ≈ 2 MB 级 | 保持现状；若 provider 切换频繁可加 idle 释放 | 无新增（确认项） | 无 | —（已合理） |
| S11 | `src/main.zig:395-3939` 各处 | 启动期固定缓冲：`cli_arg_buf: [64]`、`buffer: [max_path_bytes+2]`、help `buffer: [32 KiB]`（`commands.zig:465`） | 均在各自函数栈帧内，生命周期 = 单次调用；`writeTopLevelHelpFast` 的 32 KiB 是 FixedBufferAllocator，函数返回即释放 | 保持；无需改 | 无（确认项） | 无 | —（已合理） |
| S12 | `src/core/skills/skill_runtime.zig:1714-1748,2592-2640` | skills catalog 代际 + 原子引用计数；adopt 时零拷贝转移 `catalog.*`，旧代退休待引用归零 | 每代 skills 全量；refresh 期间新旧两代并存 | 保持；refresh 频率受 `fresh_through_generation` 约束 | 无（确认项） | 无 | —（已合理） |
| S13 | `src/usage/cache.zig:82-88,203-213,249` | usage cache `Owned` = arena + entry；`read` 后 `bytes` 即 free；`max_file_bytes=4 MiB` 上限 | 每次 `/usage` 一个 arena，deinit 归还 | 保持；`own()` 的 encode→decode 往返可省（直接构造 Owned），但仅一次性 | 每次省一次 4 MiB 以内的往返分配 | 低 | P3 |
| S14 | `src/core/compactor/compactor.zig:165-226` | `compact` 的 summary 用 caller allocator（注释明确「gives its working memory back」），仅 checkpoint/model_text 留 arena | summary 峰值 = 输入窗口大小；`Result` 保留量小 | 保持；确认 caller arena 在 turn 结束释放 | 无（确认项） | 无 | —（已合理） |
| S15 | `src/main.zig:1764-1772` | `snapshotImageCatalog` 每次入队都重建 catalog；`recovery_checkpoint` 分支先 snapshot 再 merge（两份瞬时） | 图片数 × (path+media_type+snapshot_sha256+blob_path) ≈ 每张 200–500 B；inline_data 的图片每张可达 MB 级 | catalog 改为版本化引用（图片集不变时复用上一份）；inline_data 图片尽早转 blob handle | 每 turn 省一份图片目录拷贝 | 中：图片授权/生命周期语义需保持 | P2 |
| S16 | `src/core/app/app_render_runtime.zig:235-239,257-266` | pending card 投影：`skill_tokens` alloc → `buildUserPromptCardTail` alloc `card` → `pendingCardTerminalWireBytes` 再 alloc `bytes`，帧末 free | 每帧 3 份；card 大小 ≈ prompt 尾部（KB 级） | `card` 与 `bytes` 可共用一段 arena（帧级），或直接写 frame surface | 每帧少 1–2 次分配 | 低 | P3 |

## 3. 已验证合理的域（静态确认，无节省空间或收益可忽略）

- **skills 缓存**：`skill_runtime.zig` 的 `CatalogGeneration` 引用计数 + adopt 零拷贝（`:2610-2626`），refresh 期间旧代仅在有 lease 时保留，无重复表示。
- **model_cache**：`adoptOwnedCatalog`（`:753-786`）先 free 旧 catalog 再换新，单份常驻；加载仅由 activity/picker_open 触发（`:30-36`），idle 不轮询。
- **file_index 代际**：`active_generation`/`loading_generation` 切换，`joinThreadIfDone` 后旧代 destroy；`countAndSize` 精确预分配 `paths_buf`/`lower_buf`（`RawTotals` 注释明确），无过度预留。
- **usage 缓存**：`cache.Owned` 的 arena 随 entry 一并 deinit；`read` 后 `bytes` 立即 free；`max_file_bytes=4 MiB` 有界。
- **compactor**：`compact` 的 summary 工作内存归 caller allocator（`compactor.zig:190-196` 注释），`Result` 只留 checkpoint/model_text/retained_history。
- **启动缓冲**：`writeTopLevelHelpFast` 的 32 KiB 是栈上 FixedBufferAllocator（`main.zig:4020-4021`）；`cli_arg_buf`、`max_path_bytes` 缓冲均为函数级栈帧。
- **auth/usage label**：`usage_host.zig:63-115` 的 `LabelBuffer=[160]u8` 借用，无 dupe。
- **modes/mods**：`src/core/modes/`、`src/core/mods/` 无 ensureTotalCapacity/arena/常驻缓存。
- **usage/credits_lookup**：均为任务级 dupe + errdefer，无常驻增长。
- **http_pool warm**：`abandoned_warm_flight` 已在 §16.5 记录，属单次确定性泄漏而非效率项，不重复计。

## 4. 需运行时证实项

| 项 | 关联 | 证实方法 | 判定标准 |
| --- | --- | --- | --- |
| 每 turn 历史深拷贝的真实峰值 | S1/S3 | 在 `snapshotHistory` 前后采样 `std.heap.c_allocator` 的 `total_bytes`/`live`，或给 App 加分配统计出口 | 若 8 turn 后单 turn 拷贝 > 4 MB，确认 P0 |
| `diff_entries` 常驻总量 | S2 | 长会话（500+ 编辑）后 VMMap `Private Data` 与 `diff_entries` 字节数对比 | 若 > 50 MB 且 materialize 未触发，确认 P1 |
| file_index `lower_buf` 实际占比 | S4 | 大仓库（>10k 文件）运行中 VMMap `Heap` 分类 | 若 `lower_buf` > 50 MB，确认 P2 |
| 线程栈真实提交（§8.10 待测项的延伸） | S8 | VMMap `Stack` 分类，对比 16 MiB 默认 vs 显式 2 MiB | 若 Stack 远低于 4.8 GiB 上界，收益按实测下调 |
| arena 高水位回落 | S7 | 全部 turn 结束后 `reset(.free_all)` 试验，对比 Private | 若 Private 降 > 100 MiB，推广到所有 >1 MiB arena |
| request body 流式化的收益 | S6 | 记录每 model step `Allocating` writer 的 `toOwnedSlice` 长度分布 | 若中位数 > 1 MB，优先做流式 |
| steering 投影每帧分配频率 | S5 | 帧率 × 每帧 alloc 次数（debug_trace 计数） | 若 > 100 alloc/s 且串长 > 1 KiB，做版本号复用 |

## 5. 与上一轮 §8 的关系

- §8.5 的三项 P0（小栈、并发上限、parallel 池化）本报告不重复，S8 只补充 `parallel_execution.zig:207-216` 的 slot arena 也应池化。
- §8.6 的「大工具结果转 handle 后尽早释放」与 S1/S2 同源：history 深拷贝里就含着工具结果副本，result_store handle 化后 S1 的拷贝基数同步下降。
- §8.11 的「空闲不退」三层原因中，本报告覆盖第 1 层（CRT 高水位）的具体来源：S2/S3/S7 的峰值分配决定高水位；降峰值比等 CRT 归还更有效。
- §16.4/§16.5 的「设计性不归还」不在本域（属泄漏类），本报告不重复定级。
