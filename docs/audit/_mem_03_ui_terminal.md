# 内存审计 03：UI 与终端域（只读静态审计）

- 范围：`src/ui/**`（transcript/、render_engine/、assistant/、footer/、input/、terminal/、approval_screen.zig、full_transcript_screen.zig 等）、`src/core/terminal/**`（engine.zig、store.zig、native_session.zig）、`src/core/input/**`。
- 基线：`docs/audit/2026-11-06-full-review.md` §8（多子代理并发内存实测）。本轮是其 §8 的域内验证与扩展，只做静态阅读 + grep，未跑 `zig build/test`，未改任何文件。
- 分配器背景：二进制用 `std.heap.c_allocator`（`build.zig` link_libc=true，Windows CRT）。因此「分配后不 free」在本域表现为 CRT 堆高水位只涨不缩；「逻辑已 free、提交不回降」不记为泄漏。

## 1) 摘要

- 本域未发现 P0（当下真实泄漏/UB）。逐帧路径（`buildAndFlushFrame`）的所有大分配都有 `defer deinit/free` 配对；`Grid` 的 resize、saved-screen、池全部成对；alternate screen 三 owner 互斥与关闭路径成对。
- 主要结构性问题是有界但不收缩的容量：transcript `entries` 在开启 transcript window 后没有条数/字节上界（P1，真实长会话条件下发生）；`notebook.transcript` 容量固定在 256 KiB 高水位（P2）；每帧 cell 缓冲 2×cols×rows×sizeof(Cell) 瞬时双分配 + 每帧克隆 shadow Grid（P2，可复用但非泄漏）；`FrameSurface` 逐帧重建 hyperlink/combining 池（P2）。
- 上一轮 §11.4 已记的「审批屏每次绘制重建整份文档布局」本轮确认：`approval_screen.paint` 每次都 `TranscriptDocumentLayout.init` + `fileDocumentLayout` + `out.toOwnedSlice()`（P2，量化为每次滚轮/箭头重绘一份文档字节）。
- 大量候选在测试代码内（`full_transcript_screen.zig` 的 154 处分配命中绝大多数在 `test` 块），已排除。

## 2) 发现表

| ID | file:line | 类型 | 严重度 | 置信度 | 机制 | 证据引用 | 建议修法 | 证实方法 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| M03-01 | `src/ui/transcript/runtime.zig:7203-7250`（`enableTranscriptWindow`/`syncTranscriptWindow`/`applyTranscriptWindowDrops`）+ `src/ui/transcript/store.zig:694-734`（`dropEntriesAtomic`/`dropEntries`）+ `src/ui/transcript/transcript_window_shell.zig:104-116`（`sync`） | 未释放内存/无界增长 | P1 | 读码确认 | 开启 transcript window 后，`max_transcript_bytes`（256 KiB，`src/main.zig:204`）只约束 `notebook.transcript` 字节缓存；`notebook.entries` 的释放完全交给 window 的 `sync` 归还 drops。`transcript_window_shell.Shell.sync` 只报告「finished 且不在屏上」的 entry；pinned（`lifecycle_pinned`，store.zig:715）、在屏、以及尚未 finish 的 entry 全部留在 `entries` 里，且没有条数上界。长会话 + 大量工具输出时 `entries`（每个 entry 自带 dupe 的 bytes/skill tokens/images，store.zig:2194-2231）随会话线性增长，`dropEntries` 永不触发或触发频率低于增长频率。 | runtime.zig:7126-7133 注释明示「the byte cap no longer applies」；store.zig:714-717 pinned 检查；store.zig:729-734 compact 只删 drops 交集 | 给 window 状态的 entries 加条数/保留字节上界（如屏行数 × N），超限时强制 drop 最老非 pinned entry；或让 `sync` 对超长前缀做整段 release | 运行时证实：长会话（>10k 条 entry）下采样 `notebook.entries.items.len` 与 `retainedStructuredBytes()`（store.zig:180）随时间单调上升且不回落 |
| M03-02 | `src/ui/transcript/store.zig:158-165`（`initBacking`/`ensurePaintReservation`）+ `runtime.zig:4740`（`max_transcript_bytes = 256*1024`） | retain_capacity 高水位只涨不缩 | P2 | 读码确认 | `ensureTotalCapacity(alloc, 256 KiB)` 一次把 `notebook.transcript` 容量钉到 256 KiB；之后 `appendCappedWithinCapacity`（store.zig:3296-3341）只 `clearRetainingCapacity`/`@memmove` 前移，容量永不缩。256 KiB 是固定常数，单实例不大，但每个子代理会话各持一份时按会话数线性放大（与 §8 的 O(N) 叠加）。 | store.zig:163-164 只在 `capacity < max` 时才 ensure，即只涨；store.zig:3307/3330 的 trim 不缩容量 | 若多会话同进程是常态，改为按需 `ensureTotalCapacity` 到 min(需要, 上限) 而非一次性钉满；或 trim 到低位时 `shrinkAndFree` | 用 `capacity` 与 `items.len` 差值在会话生命周期内采样；对比 `initBacking` 调用次数与进程内会话数 |
| M03-03 | `src/ui/render_engine/frame_builder.zig:109-113` + `src/ui/render_engine/terminal_diff.zig:980-998`（`cloneAuthoritativeShadow`）+ `frame_surface.zig:123`（`alloc(FrameCell, rows*cols)`） | 大量占用/逐帧分配 | P2 | 读码确认 | 每帧提交路径：`prepareTerminalMovementForFrame` 先 `authoritative.clone(alloc)`（整份 cells 拷贝），`FrameSurface.initFromShadow` 再 `alloc(FrameCell, rows*cols)`，`flushFrame` 里 `input.surface.copyToTargetGrid(alloc)`（terminal_diff.zig:358）又一份。逐帧瞬时峰值 ≈ 2×cols×rows×sizeof(Cell) + 一份 shadow Grid 克隆；100×40 终端按 sizeof(Cell)≈24-32 B 估算每帧约 100-200 KiB 瞬时分配，c_allocator 下反复走 CRT 堆。机制正确（都有 deinit），但每帧重复。 | frame_builder.zig:109 `initFromShadow`；terminal_diff.zig:986 `authoritative.clone`；terminal_diff.zig:358 `copyToTargetGrid` | 双缓冲：长期持有一份同尺寸 target Grid，resize 时才重建；`FrameSurface.cells` 复用同一缓冲（尺寸未变时跳过 alloc）；shadow clone 只在尺寸/内容变化时做 | 在 `buildAndFlushFrame` 前后采样 allocator 计数；尺寸不变时连续 N 帧的 alloc 次数应从 ≥3 降到 0 |
| M03-04 | `src/ui/render_engine/frame_surface.zig:131-141`（`importHyperlinkPool`/`importCombiningSuffixPool`） | 大量占用/逐帧分配 | P2 | 读码确认 | 每帧 `FrameSurface` 都 `ensureTotalCapacity(previous.hyperlink_pool.items.len)` + 逐个 `link.clone`（dupe uri/params）与 `dupe` 每个 combining suffix，`deinit`（frame_surface.zig:183-189）再全放。池大小由 engine.zig 的 `max_hyperlink_pool_bytes = 4 MiB` / `max_pool_entries` / `max_combining_pool_bytes` 上界，所以单帧有界；但逐帧整池克隆是纯浪费，链接多的会话每帧多份 KiB-MiB 级分配。 | frame_surface.zig:133 `link.clone`；frame_surface.zig:138 `alloc.dupe`；engine.zig:31/945-951 池上界 | surface 持有池的只读视图/代际引用，仅在 commit 时交换所有权；或池本身全局共享、surface 只存 id | 统计每帧 `importHyperlinkPool` 的 clone 字节数（`grid.hyperlink_pool` 总长），链接多的会话应能看到每帧 KiB 级分配 |
| M03-05 | `src/ui/approval_screen.zig:262-360`（`paintFileApproval`）+ `src/core/app/app_render_runtime.zig:1931-1952` | 大量占用/每绘制分配 | P2 | 读码确认 | 每次审批屏重绘（滚轮/箭头）都：`TranscriptDocumentLayout.init(alloc, transcript, cols)`（整份文档重排）、`fileDocumentLayout`、`writeDocumentRows` 写 `out`（Allocating writer）、最后 `out.toOwnedSlice()`。大文件审批时每帧一份文档级字节 + 布局数组；上一轮 §11.4 已记「每次绘制重建整份文档布局」，本轮确认其内存面。布局结果在 scroll 仅 ±几行时可增量复用。 | approval_screen.zig:317-327 `TranscriptDocumentLayout.init` + `fileDocumentLayout`；approval_screen.zig:362 `.bytes = try out.toOwnedSlice()`；app_render_runtime.zig:1931 每绘制调用 | 缓存上一份 `document_layout`，仅当 `document_scroll_rows`/cols 变化时重建；`out` 缓冲复用（写入前 `out.clearRetainingCapacity`） | 对同一审批请求连续滚动，统计 `TranscriptDocumentLayout.init` 调用次数与每次字节数 |
| M03-06 | `src/ui/input/runtime.zig:616-624`（`deferSessionInputByte` 前移压缩）+ `:592-596`（`deinit`） | retain_capacity 高水位只涨不缩 | P3 | 读码确认 | `deferred_session_input` 在消费后做 `@memmove` 前移压缩（runtime.zig:651-657），但 `clearRetainingCapacity` 保留容量；延迟输入峰值（limit 参数控制条数）过去后 ArrayList 容量不退。无界风险低（`limit` 门控），属小浪费。 | runtime.zig:622-629 前移；runtime.zig:601 `clearRetainingCapacity` | 压缩后若 `items.len == 0` 且 `capacity > 某阈值`，`shrinkAndFree` 回小容量 | 采样 `deferred_session_input.capacity` 在批量延迟输入前后的值 |
| M03-07 | `src/core/terminal/engine.zig:597-612`（sync_buffer 重启）+ `:736-775`（osc/dcs 有界 append）+ `:928-963`（hyperlink pool 上界）+ `:1053-1077`（combining pool 上界） | 已核实：上界正确 | 干净 | 读码确认 | `appendBounded`（engine.zig:3301）在 `max_sync_bytes`/`max_string_bytes` 处丢弃而非增长；hyperlink pool 有 `max_pool_entries` 与 `max_hyperlink_pool_bytes = 4 MiB` 双门限并触发 compaction（engine.zig:941-951）；combining pool 有 `max_pool_entries`/`max_combining_pool_bytes`/`max_cell_text_bytes` 三门限；`deinit`（engine.zig:400-415）释放 cells/tab_stops/三池/saved 屏幕，无遗漏分支。 | engine.zig:31, 3301, 945-951, 1061-1065, 400-415 | 无需修 | 已读全部分配点并核对 deinit 配对 |
| M03-08 | `src/core/terminal/engine.zig:426-490`（`Grid.resize`）+ `:499-526`（`resizedCells`）+ `:196-252`（`SavedScreen` 所有权转移） | 已核实：resize 成对 | 干净 | 读码确认 | resize 分配新 cells/tab_stops/saved 屏幕（`errdefer free` 覆盖每条失败路径），成功路径先释放旧 `self.cells`/`tab_stops`（engine.zig:463-464）再换指针；`SavedScreen.capture/restoreTo` 是所有权转移而非拷贝（engine.zig:196-230），`dupe` 仅用于深拷贝且带 errdefer。旧切片在 free 后不被引用（读码未见 reset 后复用旧 `cells` 的路径）。 | engine.zig:439-479 全路径 errdefer；engine.zig:463-464 先 free 后赋值；engine.zig:226 `grid.cells = saved.cells` 所有权交接 | 无需修 | 逐路径核对 errdefer 链 |

## 3) 已验证干净的区域及理由

- **每帧提交主路径所有权配对**：`frame_builder.buildAndFlushFrame`（frame_builder.zig:73-131）中 `movement`（`defer movement.deinit(alloc)`）、`surface`（`defer surface.deinit()`）、`flushFrame` 内 `target`（terminal_diff.zig:358-359 `defer target.deinit()`）、`bytes` writer（terminal_diff.zig:1236-1237 `defer bytes.deinit()`）全部成对；错误路径由 `errdefer` 覆盖。
- **`PreparedTranscriptSurfacePaint` 生命周期**：`app_render_runtime.zig:1305` 与 `:2160` 双重保险（声明处 `defer prepared.deinit` + 固定点重试处先 deinit 再置 null），prepared 内部的 `owned_bytes`/`source_visible_lines` 等 ArrayList 均在 `painter.zig:1140-1158` 的 deinit 里逐项 free。
- **alternate screen 三 owner 互斥与关闭**：`app_lifecycle.zig:1618-1651` 的 enter/leave/mouse-tracking 三个函数以 `alternate_screen_owner` 枚举做唯一所有权检查（enter 拒绝双重占用 `.none`→error，leave 校验 owner 匹配），`leaveAlternateScreens`（app_lifecycle.zig:1337-1345）在退出时按 owner 分派释放；`openFullTranscript` 的 `errdefer`（app_lifecycle.zig:1522-1528）在投影切换失败时回滚。状态机层面无持有泄漏。
- **`full_transcript_screen.zig` 的 154 处分配命中**：逐条核对后几乎全部位于 `test` 块或 `FixedBufferAllocator` 限界沙箱内（如 :1217/:1300/:2700/:2885/:2994 的 `bounded_memory`，:4336 的 192 KiB scratch 带 `defer alloc.free`，full_transcript_screen.zig:4336-4345）；运行时分配（ProjectionRowWalker/CommandByteReader）均有 `deinit`。
- **`src/core/input/edit_history.zig`**：undo/redo 双栈有 `max_entries = 100` 上界（edit_history.zig:5, 107-110），`clearStack` 逐项 deinit（edit_history.zig:148-158）。
- **图片附件 UI 侧拷贝**：生产路径 `input_submit_runtime.zig:36-41`（`dupeImageAttachmentSlice` + `errdefer freeImageAttachmentSlice` 配对）与 `app_input_runtime.zig:12438-12441`（`freeQueuedImageMetadata` 在 deinit 与 enqueue 覆盖点调用）成对；`app_input_runtime.zig:12279` 的 `FakeSubmitApp` 是测试 fake，其 `queued_images` 配对也完整（12524-12531）。
- **`src/core/terminal/native_session.zig`**：抽样 359-368、877、987-988、1035、1057、1544-1572、1603-1610、1685-1715 均见 `defer free/deinit` 或 `errdefer`；Session 的 `deinit`（1603-1610）释放全部 7 个拥有字段。
- **`src/core/terminal/store.zig`（ProfileStore）**：`init_with_options` 524-534 的 `errdefer` 覆盖 joined 路径前缀；`deinit`（544-548）释放 residents + 两条 display path；`CatalogList` 条目 866-875 逐字段 errdefer。

## 4) 疑似但未证实

- **M03-S1**：`src/ui/transcript/runtime.zig:13781` 与 `:14684` 的 `notebook.transcript.appendSlice(alloc, ...)`（resume/replay 路径）未走 `appendCappedWithinCapacity`，若追加总量超过 256 KiB 会绕开 cap。读码未见这两处的调用方有前置 trim，疑似在恢复投影安装瞬间产生 >256 KiB 的瞬时占用。需运行时证实：恢复大日志会话时采样 `notebook.transcript.items.len` 是否短暂超过 `max_transcript_bytes`。
- **M03-S2**：`painter.zig:3345` `const head = try alloc.alloc(u8, std.math.maxInt(u16))`（约 64 KiB）位于测量/调试函数，调用频率与是否每帧执行未确认；若被帧路径调用则是每帧 64 KiB 浪费。需 grep 调用方 + 运行时计数证实。
- **M03-S3**：`store.zig:847`/`:1577` 的 `cappedTailStart(rendered, max_transcript_bytes)` 重建缓存路径在 `rebuildTranscriptFromRendered`（store.zig:168-177）里先 `ensureTotalCapacity(bytes.len - start)` 再 `clearRetainingCapacity`，若渲染输出远大于 256 KiB 会瞬时装下大缓冲再 trim。疑似峰值放大，需证实。
- **M03-S4**：`footer/` 域（input_presentation.zig、picker_presentation.zig 等 2000-3000 行级文件）本轮只做了分配点计数（每文件 ≤75 处命中且多为测试），未逐条追踪；`footer` 每帧测量/绘制路径的逐帧分配未完全核实。

## 5) 可量化的节省机会

| 项 | 位置 | 现状 | 节省估算 |
| --- | --- | --- | --- |
| 双缓冲复用 cell 缓冲 | frame_builder.zig:109、terminal_diff.zig:986、terminal_diff.zig:358 | 每帧 ≥2 份 rows×cols cell 拷贝 + 1 份 shadow 克隆 | 100×40 终端每帧省约 100-200 KiB 瞬时分配；流式输出 60fps 下每秒省 6-12 MB 堆流量 |
| 审批屏布局缓存 | approval_screen.zig:317-327、362 | 每次滚轮/箭头重绘重建整份文档布局 + 一份 owned bytes | 大文件审批每帧省一份文档字节（文档 1 MiB 时每帧 1 MiB）；同时缓解 §11.4 的 CPU 问题 |
| FrameSurface 池共享 | frame_surface.zig:131-141 | 每帧克隆整个 hyperlink/combining 池 | 链接密集会话每帧省 KiB-至多 4 MiB 上界的池克隆 |
| transcript entries 上界 | runtime.zig:7203-7250 | window 模式下 entries 无条数上界 | 长会话从无界降为 O(屏行数 × 常数)，数量级取决于会话长度 |
| transcript 容量按需 | store.zig:158-165 | 每会话钉 256 KiB | 多子代理会话同进程时按会话数线性节省（每会话最多 256 KiB 高水位） |

## 附：方法与排除

- 分配点清点用 grep（`alloc(`/`allocPrint`/`dupe`/`create`/`toOwnedSlice`/`ArrayList`/`HashMap`/`arena`/`reset(`），命中数最高文件：full_transcript_screen.zig 154（几乎全测试）、core/terminal/store.zig 105（ProfileStore 持久化，配对完整）、transcript/runtime.zig 88。
- 全域未发现 `ArenaAllocator.reset(.retain_capacity)`（grep 无命中），也未发现 `@panic`/`undefined` 解引用类悬垂证据；`@memmove` 前移（store.zig:3329、runtime.zig:651）均在长度同步更新后执行，未见 reset 后复用旧切片。
- 未运行任何构建/测试/二进制；所有结论均为静态读码证据，置信度已在表内标注。
