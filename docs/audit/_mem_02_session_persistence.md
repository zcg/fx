# 内存审计 02：持久化与会话层（只读静态审计）

- 范围：`src/core/session/**`、`src/core/session_manager/**`、`src/core/config/**`、`src/core/skills/**`、`src/core/workspace/**`、`src/core/profiles/**`（约 10.5 万行）。
- 方法：先 grep 全部候选分配点（`alloc`/`allocPrint`/`dupe`/`dupeZ`/`create`/`destroy`/`ArrayList`/`HashMap`/`toOwnedSlice`/`arena`/`reset(.retain_capacity)`/`parseFromSlice(Leaky)`），再对每个候选读所在函数，逐路径（成功/出错/恢复/关闭/导入）追踪「谁分配、谁释放、defer/errdefer 是否成对」。
- 限制：本轮只做静态阅读 + grep，未跑 `zig build`/`test`，未做运行时采样；上一轮 `docs/audit/2026-11-06-full-review.md` §8/§9/§16 的结论作为基线逐条复核。
- 结论：**本域未发现可证实的 P0（当下真实泄漏/UB）或 P1**。确认发现 6 条：P2 × 3（高水位/峰值浪费，均有界），P3 × 3；另有 3 条疑似未证实。上一轮 §9.10 的干净结论在本轮复核成立。

## 1. 摘要

| 严重度 | 数量 | 说明 |
| --- | ---: | --- |
| P0 | 0 | 无证实的实时泄漏/UB |
| P1 | 0 | 无真实条件下很可能发生的泄漏 |
| P2 | 3 | MEM-02-01/02/03，有界浪费或峰值放大 |
| P3 | 3 | MEM-02-04/05/07（07 为疑似） |
| 疑似未证实 | 3 | MEM-02-06/07/08 |

主导结论：v2 session manager 的 resume/append/close/destroy 全链路所有权成对（`Parts.deinit`、`Loaded.deinit`、`Identity.deinit`、`State.deinit`、`errdefer` 全覆盖）；adapter 层 `destroyInner`/`clearStreamed` 释放所有常驻容器；settings_store 的 advisory lock + fingerprint 重试 + 随机临时名 + rename + 目录 sync 全部成对；result_store 的 raw/sanitized/capped/durable 多份拷贝均有显式字节上界。浪费集中在「clearRetainingCapacity 保留的容量高水位」与「v1 家族转换时 checked[] 全量驻留」，均非单调泄漏。

## 2. 发现表

| ID | file:line | 类型 | 严重度 | 置信度 |
| --- | --- | --- | --- | --- |
| MEM-02-01 | src/core/session_manager/session.zig:507-508,786-787,1790-1791（字段 :229-233） | 高水位不缩 | P2 | 读码确认 |
| MEM-02-02 | src/core/session/session_adapter.zig:3390-3396（对照 :3388 注释） | 峰值放大 | P2 | 读码确认 |
| MEM-02-03 | src/core/session/result_store.zig:151-234（常量 :15-20） | 瞬时多份拷贝 | P2 | 读码确认 |
| MEM-02-04 | src/core/session/session_adapter.zig:1602,1608,1610,2463（增长 :1739） | 高水位不缩 | P3 | 读码确认 |
| MEM-02-05 | src/core/config/settings_store.zig:586,640,652 | 重复读/瞬时副本 | P3 | 读码确认 |
| MEM-02-06 | src/core/session/session_codec.zig:427（调用点未全读） | 潜在无界解码 | P2 | 疑似，需运行时证实 |
| MEM-02-07 | src/core/session/session_adapter.zig:4637-4644（对照 :4588-4589） | 借用/UAF 风险 | P3 | 疑似 |
| MEM-02-08 | 任务书占位符 `session/workspace` | 无法定位 | — | 需任务书澄清 |

### MEM-02-01（P2）session_manager 每会话 append 缓冲容量高水位
- 机制：`held` 用 `clearAndFree`（:535、:963）真释放；`batch`/`bounds`/`bodies` 只 `clearRetainingCapacity`（:507-508、:786-787、:1790-1791）。一次达到 `max_line_bytes = 4 MiB`（log.zig:21，`max_value_bytes` 为其减 64 KiB，api.zig:60）的大 append 后，容量保留到会话关闭，空闲会话不缩。
- 证据：`src/core/session_manager/session.zig:229-233`（字段）、`:507-508`、`:535`、`:786-787`、`:963`、`:1790-1791`；`log.zig:21`；`api.zig:60`。
- 量化：每打开会话最坏保留 ≈ 4 MiB（batch）+ bounds/bodies 小量；M 个并发打开会话 → O(M × 4 MiB) 保留，典型为一轮 turn 的字节数。
- 修法：publish/fsync 成功后对 `batch`/`bounds`/`bodies` 做 `shrinkAndFree`，或保留容量上限（如 64 KiB）；`destroy` 路径已 `deinit`，不变。
- 证实：`zig build test` 加 allocation-count 断言；运行时对 append 大 batch 前后采样 RSS/VMMap `Private Data`。

### MEM-02-02（P2）v1 家族转换 checked[] 全量驻留
- 机制：`family()` 先为全部 member 做 `checked.appendAssumeCapacity(try c.check(...))`（:3390-3396），`Checked.read` 持有一份 v1 `Member` 全量状态，直到函数末尾 `defer` 才 `member.deinit()`（:3391-3393）。注释（:3388）「memory holds one member at a time」只覆盖 `staged`，不覆盖 `checked`。K 个子会话的家族峰值 O(K × member)。
- 证据：`src/core/session/session_adapter.zig:3385-3411`（`checked`/`staged` 两段）、`:3392`（deinit 时机）、`v1_conversion.readMember` 全量读（:3443-3452 同款）。
- 修法：两阶段——第一遍只校验 id/fingerprint（不持有 Member），第二遍逐个 stage+释放，与 `staged` 的「一次一个」语义一致。
- 证实：构造 K=20、每 member 5 MiB history 的 fixture，测 `c_allocator` 峰值；预期 100 MB → 5 MB。

### MEM-02-03（P2）result_store 大结果 prepare 的瞬时多份拷贝
- 机制：`prepare*` 为一个大结果同时持有 `durable_output`（输入）+ `handle` + `preview`（4 KiB）+ `model_output`（stored 路径为 format 串，inline 路径为全量 dupe）+ 一次磁盘写。均有上界：`stored_text_max_bytes = 8 MiB`（:20）、`preview_bytes = 4 KiB`（:16）、`read_max_bytes = 64 KiB`（:18）、`large_result_threshold_bytes = 16 KiB`（:15）、diff pack `2 × 8 MiB`（:322）。
- 证据：`src/core/session/result_store.zig:151-234`（errdefer 成对）、`:624-635`（cappedInlineOutput）、`:459-466`、`:485-524`、`:821-829`（handle ≤160 B + 字符集）。
- 修法：沿用 §8 建议——borrowed fast path、先按 cap 取 prefix 再 sanitize、durable full output 流式写文件；保留 `output_handle`/`stored_output_bytes`/`truncated`/`preview` 语义。
- 证实：对 8 MiB 结果跑 prepare，用 failing allocator + 峰值计数对比修前修后。

### MEM-02-04（P3）adapter 每轮 turn 容器容量高水位
- 机制：`streamed`/`stored_results`/`running`/`turn_numbers` 结束时均 `clearRetainingCapacity`（:1602、:1608、:1610、:2463），`turn_numbers` 每 commit +1（:1739）。一轮大 turn 的峰值容量保留到会话关闭。
- 证据：`src/core/session/session_adapter.zig:1599-1611`、`:1739`、`:2463`。
- 修法：超过阈值（如 256 KiB）时 `shrinkAndFree`；`turn_numbers` 在 compact 时清零（已有 :2463 调用点，顺手 shrink）。
- 证实：长会话多轮大工具结果后采样 RSS 平台期。

### MEM-02-05（P3）settings 提交每 attempt 三读 primary
- 机制：`applyMutationImpl` 每个 attempt 读 `primary`（:586）、`latest`（:640）、`precommit`（:652）各一次，每次 ≤ `max_settings_bytes = 64 KiB`（:21）；3 次 attempt 最坏 9 次读、3 份瞬时 64 KiB。有界，但 `latest`/`precommit` 目的相同（fingerprint 复核），可合并。
- 证据：`src/core/config/settings_store.zig:584-660`、`:21-25`、`:802-844`（loadRawPrimary）。
- 修法：`latest` 与 `precommit` 合并为一次读 + 一次内存 fingerprint 比对；或仅在 `application.changed` 时读 precommit。
- 证实：读码即确认；量级小，收益为 I/O 而非内存。

### MEM-02-06（P2，疑似）DurableSessionState 全历史解码上界依赖调用方
- 机制：`DecodeLimits.max_history_turns` 默认 `std.math.maxInt(usize)`（session_codec.zig:427），`max_value_bytes` 默认半无穷（:428）。若 v1 `restore()` 调用点未传限制，每次 resume 解码 O(整个会话历史)，叠在 v2 manager 已有的「快照+尾部」有界折叠（session_manager/session.zig:1356-1433）之上。js_host 路径已显式传 `max_history_turns = 100_000`（js_host_session_store.zig:98）、ACP 传 8/100，说明「调用方负责」是既有模式，但 adapter 的 restore 调用点本轮未逐一读完。
- 证据：`src/core/session/session_codec.zig:427-428`、`:303-326`；`src/core/session/session_adapter.zig:2743-2747`（durableState → restore → resumedOf）。
- 修法：restore 强制传 `max_history_turns = 1024`（与 `src/core/agent/runtime/checkpoint.zig:29` 同款）或按需分页。
- 证实：grep restore 全部调用点的 `limits` 实参；resume 一个万 turn 会话测 RSS 曲线。

### MEM-02-07（P3，疑似）replay 的 builder 借用语义跨页悬垂
- 机制：`replay()` 每页 `defer page.deinit()`（:4588-4589）在迭代末释放页 arena；注释（:4638-4640）「The builder copies what it keeps … so strings may point into the page」自相矛盾——若 `ConversationTurnBuilder` 任一 append 存的是 page/piece arena 的 slice 而非拷贝，下一页 `page.deinit()` 即 UAF。`piece_arena`/`turn_arena` 每行/每 turn `reset(.retain_capacity)`（:4591、:4599）本身无误（函数级 defer deinit）。
- 证据：`src/core/session/session_adapter.zig:4571-4668`；`session_log.zig:1231+`（ConversationTurnBuilder，未读全文）。
- 修法：统一 builder 语义为「全部拷贝」，并在注释写明所有者；或让 page 生命周期覆盖整个 replay。
- 证实：读 `session_log.zig:1231-1400` 的 append* 实现；用 failing allocator + ASan 等价检查跑 replay 测试。

### MEM-02-08 任务书占位符无法定位
- 任务书问「key 为 `session/workspace` 的 map 是否随会话数线性增长且不回收」。域内 grep（`StringHashMap`/`array_hash_map`/`AutoHashMap` 全量）未发现任何以该 token 为 key 的 map；本域 map 全部为每会话/每请求生命周期或一次性加载（session_adapter.zig:934/1061/1243/1249、session.zig:1420、command_replay_store.zig:141、catalog.zig:173、session_catalog_cache.zig:105/149、file_index.zig:754/970/1089）。需要任务书给出真实符号名才能定位。

## 3. 已验证干净的区域及理由

1. **v2 resume 全链路**（session_manager/session.zig:1220-1433）：`openResume`→`openParts`→`loadFolded` 每个获取都有 `errdefer` 或 `defer`；`Parts.deinit`/`Loaded.deinit`/`Identity.deinit`/`State.deinit` 成对；`repair()` 在 `writeBodies` 前把 child id/work_id 拷进 `copies` arena（:1468-1473），避免 fold 后借用移动；`line_arena` 每行 `reset(.retain_capacity)`、函数末 deinit（:1409-1415）。
2. **fold 所有权**（session_manager/fold.zig:29-46,94-121,398-422）：`State` 拥有每个 slice；`deinit` 释放 setting_fields + children + 列表；`clone`/`decodeState` 的 errdefer 链完整；解析 scratch 走 arena、状态走 gpa，分界清楚。
3. **catalog/index**（session_manager/catalog.zig:171-243,307-392）：`Index` 经 arena 拥有一切；`load`/`list`/`resolve` 各自 arena/`defer`；`IndexLock` 常驻 fd 与 `baseline_bytes` 压缩阈值（:283-300）使 index.jsonl 有界（1 MiB 默认，api.zig:92）。
4. **Manager/Session 句柄**（session_manager/api.zig:172-200,598-601,610-640）：`init/deinit` 成对；`release()` 先 close 后 destroy；`updateIndexAs`/`indexSummary` 用请求级 arena；`peek`/`lastOpened`/`list` 的返回所有权文档化且测试侧 `defer free`。
5. **adapter 常驻容器**（session/session_adapter.zig:1578-1611）：`destroyInner` 释放 capability、streamed 各字节、stored_results 键值、running、prompt_blobs 键值、turn_numbers、language/instructions/first_title、files_path；`clearStreamed` 先 free 再 clear。
6. **resume 重建 DurableSessionState**（:2743-2747,4486-4517）：`durableState` 的 `restored` 由 defer deinit；`resumedOf` 以 errdefer 链复制 id/origin/workspace，并通过置空源字段完成所有权转移（:4513-4515），无双重释放、无重复分配残留。
7. **result_store 上界与释放**（result_store.zig 全文）：handle ≤160 B + 字符集 + `..` 拒绝（:821-829）；read 页 ≤64 KiB（:496）；stored 文本 ≤8 MiB（:512、:740）；search 50 行/64 KiB 双 cap（:562）；`openReaderManaged` 二选一拥有 file 或 bytes（:585-605）；所有 prepare 路径 errdefer 成对。
8. **settings_store 提交**（settings_store.zig:559-712）：advisory lock `defer release`（:577-582）；3 次 attempt 的 primary/latest/precommit 均 `defer deinit`；arena `defer deinit_arena`；candidate 即时 free；recovery_paths 由 `recovery_paths_owned` 标志在 indeterminate 与成功两路径恰好转移一次（:632-633、:674-679、:699）；backup 5/corrupt 3 修剪（:24-25、:846-856）；`durableReplaceVerifiedWithOps` 随机临时名 + rename + fsync + 目录 sync（io.zig:1033-1105）。
9. **file_index 世代**（workspace/file_index.zig）：active/loading 两代指针主线程独占；adopt 时 destroy 上一代（:424-429）；deinit 双代全收（:309-331）；缓存每 scope 只消费一次（:371-378）；`max_indexed_files = 100_000`、`max_search_results` 有界（:25、:615）。
10. **catalog cache**（session/session_catalog_cache.zig）：`Loaded` 每次 list 加载一次、`defer deinit`（:438-439）；`max_bytes = 64 MiB`、`max_records = 100_000`（:25-26）；worker 用独立 c_allocator 并在 defer 逐项释放（:441-450）。
11. **prompt history / web-fetch artifacts / js host stores**：prompt_history 1 MiB compact + 256 KiB record 上限（:13-16、:137-142、:333）；web_fetch 50 MiB/1024 文件（web_fetch_artifacts.zig:10-11）；js_host 双 store 容量倍增有硬上限且缓冲函数级 free（js_host_session_store.zig:6-8,67-105；js_host_prompt_history.zig:6-7,49-80）。
12. **session log**（session_manager/log.zig）：batch 由调用方 arena 构建、一行一帧、`sealFrame` 拒 >4 MiB（:100-107）；reader 的 ReadBuffer rawAlloc 配 deinit（:494-523）；`inspectTail` 上界 `3 × max_line_bytes + block`（:417-418）。
13. **v1 转换其余路径**（session_adapter.zig:3356-3486、v1_conversion.zig:131-241）：locks `defer release`；`staged` 先 publish 后 drop、errdefer 双保险；salvage 的 registry arena 函数级 deinit；`rootIds`/`strayChildren` 的 `toOwnedSlice` 与逐项 free 成对。
14. **skills catalog**（skill_runtime.zig:1714-1748,2295-2307,2557-2640）：`CatalogGeneration` 引用计数；adopt 时 `reapRetiredCatalog` + 旧 active 释放或转 retired；`freeLoaded` 区分 catalog 持有与自有；`deinit` 收 task/pending/retired/menu。
15. **上一轮 §9.10 复核**：`parseFromSliceLeaky` 所有权与 std.json 契约一致；settings 的 lock/fingerprint/临时名/fsync/rename/indeterminate 齐全；凭据与 blob 路径的字符集校验、`VerifiedDir` 策略不变；v2 日志的版本/torn tail/CRC/snapshot replay 机制未引入分配问题。

## 4. 疑似但未证实

1. **MEM-02-06**：v1 `restore()` 是否传 `DecodeLimits`（session_codec.zig:427 默认无界）。需读 `session_adapter.zig` 的 `restore` 全文与全部调用点。
2. **MEM-02-07**：`ConversationTurnBuilder` 是否全拷贝（session_log.zig:1231+）。注释自相矛盾，跨页借用即 UAF。
3. **MEM-02-08**：`session/workspace` keyed map 在本域不存在；需任务书给出真实符号。
4. **§8.11 第 3 项的域内对应**：怀疑「223 个会话的 arena 驻留」——本域证据反对该怀疑：v2 manager 的 `Session` 在 `release()` 后 `destroy()`（api.zig:598-601），adapter `close()` 先 release 后 destroyInner（session_adapter.zig:1547-1558），无会话级常驻 arena；若空闲仍不退存，嫌疑在 §8 已指的线程池/CRT 高水位，不在本域。

## 5. 可量化的节省机会

| 项 | 机制 | 量级 | 修法 |
| --- | --- | --- | --- |
| MEM-02-01 | batch/bounds/bodies 保留容量 | 最坏 ≈4 MiB/打开会话；M=20 并发 ≈ 80 MB 峰值保留 | publish 后 shrinkAndFree 或 64 KiB 保留上限 |
| MEM-02-02 | checked[] 全量驻留 | K=20、每 member 5 MiB：100 MB → 5 MB | 两阶段校验 |
| MEM-02-03 | prepare 瞬时 2-4 份 | 8 MiB 上限结果每次 prepare 省 8-16 MB 瞬时峰值 | borrowed fast path / 先 cap 后 sanitize / 流式写 |
| MEM-02-06 | 全历史解码 | 万 turn 会话 resume 从 O(history) 降到 O(1024) 窗口 | restore 强制传 max_history_turns |
| MEM-02-04 | turn 容器容量 | 一轮大 turn 的字节数/会话 | 超阈值 shrink |
| MEM-02-05 | 三读 primary | ≤9 次 × 64 KiB 读/提交（I/O 为主） | latest/precommit 合并 |

合计：本域无 GB 级候选；可回收的是「打开会话数 × 轮峰值」的常数因子，与 §8.11「静止占用」的主因（线程栈/CRT 高水位）不在同一层。
