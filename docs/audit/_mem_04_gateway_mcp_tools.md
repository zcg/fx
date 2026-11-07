# 内存审计报告 04：网络与工具面（gateway / MCP / tools / tooling / execution / auth 周边）

- 范围：`src/gateway/**`、`src/mcp/**`、`src/core/mcp_host/**`、`src/core/mcp/**`、`src/tools/**`、`src/core/tooling/**`、`src/core/execution/**`、`src/core/auth/**`、`src/core/slack/**`、`src/core/github/**`、`src/core/notifications/**`、`src/core/upgrade/**`、`src/core/feedback/**`、`src/core/hooks/**`（约 69,232 行）。
- 方法：静态阅读 + grep（分配点、arena reset、defer/errdefer、toOwnedSlice、readFileToEnd、清零点）。未运行 zig build/test，未修改任何文件。
- 基线：`docs/audit/2026-11-06-full-review.md` §8。该轮结论为「静态未发现足以解释 GB 级占用的真实泄漏；主导项是线程栈提交与 CRT 堆高水位」。本轮在其范围内验证并扩展，**未发现能推翻该结论的新证据**。

## 1. 摘要

- 共 12 条发现：P1×1、P2×4、P3×1、观察项×4、已核实干净×2；另有 5 条疑似未证实（§4）。
- 域内整体水平高：SSE 流、HTTP body、MCP engine/auth/http 三层、command_runner、tool_result_limits、auth 密钥材料均有显式上限、成对释放、`secureZero` 清零。
- **P1（M-01）**：`consumeSseStreamTraced` 的 replay 构建在生产默认 `content_capture_limit = null` 下无界——每字节文本既进 `content_buf` 又进 `replay`（`GatewayReplayBuilder`），双倍保留于整个流期间；且 `event_arena` 用 `reset(.retain_capacity)`，单事件 JSON 树释放后高水位保持（上限 32 MiB/事件）。主模型请求路径确实以 null 调用（`gateway_step.zig:212/498/557/621`、`orchestrator.zig:7930`、`stream_provider.zig:784/895`），只有 cache warmer 与标题生成传了上限。
- **P2（M-05）**：`mcp/auth/client.zig` 的 `signIn` 有 `flow.phase == .idle` 守卫，但 `stepFlow(.failed)`（:513）与 `.refused` 只置 `stage = .idle`，不重置 `flow.phase`；一次失败登录后再次 `signIn` 会跳过 flow arena 重置，直接覆盖 `redirect_uri` 等字段，属生命周期不对称（非泄漏，arena 整体仍在 deinit 释放）。
- 其余 P2/P3 为「保留容量不收缩」类有界浪费与一处 errdefer 语义误用（已核实无害）。
- §4 给出可量化节省：replay 引用化 + 显式上限（主路径每 token 流峰值可降近一半）、event arena 周期收缩、event_arena 高水位复用。

## 2. 发现表

| ID | file:line | 类型 | 严重度 | 置信度 | 机制 | 证据引用 | 建议修法 | 证实方法 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| M-01 | `src/gateway/client.zig:4371-4478`（调用点 `src/core/agent/runtime/gateway_step.zig:212,498,557,621`、`src/core/agent/runtime/orchestrator.zig:7930`、`src/core/agent/stream_provider.zig:784,895`、`src/builtins/gateway.zig:393`） | 无界增长 / 双份保留 | P1 | 读码确认 | `content_capture_limit` 为 null 时 `capturedText` 返回全文（:3253-3258），`content_buf` 无限增长；同一条件下 `replay.observe(root, ...)`（:4478）也保留全部事件。文本每字节在流期间被保留两份。`event_arena` 每事件 `reset(.retain_capacity)`（:4447），32 MiB 单事件上限（:227）使 JSON 树高水位保持。 | `client.zig:4371` `content_buf`、`:4373` `replay`、`:4447` reset、`:4478` `if (content_capture_limit == null) try replay.observe(...)`；`builtins/gateway.zig:393` 与 `cache_warmer.zig:310` 对比 | 1) replay 改为引用 `content_buf` 的区间（offset+len）而非再存一份；2) 给 replay 设与 capture 同一上限；3) 流结束后对 `event_arena` 做一次 `reset(.free_all)` 或按 `retain_capacity` 高水位阈值收缩 | 对 `consumeSseStream` 加一个 1 MiB 文本流用例，分别统计 `content_buf` 与 replay 占用（现有 :4925 的 `arena.queryCapacity() <= output_bytes*4` 断言可改造为双份占用上限断言）；生产路径以 `content_capture_limit=null` 跑长输出模型请求，前后采样 `Private Bytes` |
| M-02 | `src/gateway/client.zig:4447` | 保留容量高水位 | P2 | 读码确认 | `defer _ = event_arena.reset(.retain_capacity)` 位于循环体内（已用 Zig 语义测试确认每迭代末执行，非泄漏），但 retain_capacity 使最大单事件 JSON 树的提交量在流结束后不归还；`max_sse_event_line_bytes = 32 MiB`（:227）是理论高水位。 | `client.zig:4447`、`:227`；`sse.Reader` 的 `max_event_bytes` 上限（`src/gateway/sse.zig:44,75,78,119`） | 流结束（终态事件/取消/EOF）后改 `reset(.free_all)`，或仅在事件树超过阈值（如 4 MiB）时收缩 | 构造一个 8 MiB 单事件流，终态后断言 `event_arena.queryCapacity()` 回落到接近 0 |
| M-03 | `src/gateway/client.zig:4488,4506-4509,4542-4546` 等 | 生命周期不对称（疑似） | P2 | 疑似 | `resolved_model`/`provider_failure_detail`/`generation_id` 均为「后到覆盖先到」语义：`resolved_model` 仅首次分配（:4488，重复只置 invalid 标志），`provider_failure_detail` 先 free 旧值再存新值（:4506-4509），均由 `defer` 释放（:4396,4408）。覆盖路径本身成对，但「同一事件多次 error」时旧值释放与新值分配交错，OOME 路径下需逐条核对。 | `client.zig:4396,4399,4401,4408` 的 defer 组；`:4506-4509`、`:4542-4546` | 抽样核对每条覆盖路径（已完成，未见失对）；如要加固，把覆盖统一收进 `replaceOwned(alloc, *?[]u8, new)` helper | 对 `consumeSseStreamTraced` 跑 `std.testing.checkAllAllocationFailures`，在 OOM 注入下断言无泄漏（现有 :4903 测试未覆盖 OOM 注入） |
| M-04 | `src/mcp/auth/client.zig:353,472,758` | 生命周期不对称 / 残留状态 | P2 | 读码确认 | `signIn` 的 `flow.phase == .idle` 守卫（:351）依赖 `stepFlow(.failed)` 会把 phase 带回 idle；但 `.failed` 只置 `a.stage = .idle`（:513），`.refused` 两者都不置。一次失败/拒绝后再次 `signIn` 跳过 `_ = a.flow_arena.reset(.retain_capacity)`，直接在旧 arena 上覆盖 `redirect_uri` 等字段。不泄漏（arena 整体在 deinit 释放），但保留容量语义被绕过、旧字段语义残留。 | `client.zig:351-356`、`:472`、`:495-513`（`.failed` 分支）、`:507-508`（`.refused` 分支无 stage/phase 重置） | `.failed`/`.refused` 分支统一走一个 `resetFlow()`：`flow_arena.reset(.retain_capacity)` + `stage = .idle` + `phase` 归位；或把守卫条件改为 `stage == .idle`（与 :352 的 probe 守卫同口径） | 单元测试：signIn → 强制 `.failed` → 再 signIn，断言 flow arena 被重置且 `redirect_uri` 是新分配（现有 `deinit` 断言可扩） |
| M-05 | `src/mcp/io/http.zig:223` | 保留容量高水位 | P2 | 读码确认 | `claim()` 对每个 slot `_ = slot.arena.reset(.retain_capacity)`，复用是对的（header/body/响应都进同一 arena），但 `max_message = 16 MiB`（:26）意味着一个大响应后该 slot 的 arena 高水位在进程生命周期内保持。slot 数 = `max_in_flight + waiting_room`，总量有界。 | `http.zig:223`、`:26`、`:153` | 对 `>1 MiB` 的响应在结束后追加一次 `reset(.free_all)`，或给 arena 设高水位阈值回收 | 对一个 slot 连续跑「1 MiB 响应 → 小请求」，断言第二次请求后 arena 容量回落到小请求量级 |
| M-06 | `src/gateway/client.zig:1741-1750`（`defer req.deinit()` 于 :1821，循环内） | defer 作用域 | P3 | 读码确认（无害） | `defer` 在 while 循环体内，Zig 语义为每迭代末执行（已用最小程序验证），因此 `req`、`addresses`、`host_header`、`response` 的释放恰好覆盖每次尝试；非泄漏。记录此条是为了防止后续重构把 `defer` 上移到循环外而变成真泄漏。 | `client.zig:1741` 循环头、`:1750`、`:1821`；`/tmp/defer_test.zig` 语义验证输出 | 无需修；若重构，移动 defer 时同步加注释 | 无需；代码审查守则里加一条「循环内 defer 不得上移」 |
| M-07 | `src/tools/web/http_fetch.zig:141-250` | 双份拷贝（有界） | 观察项 | 读码确认 | 成功路径把 `response.body` 再 `dupe` 进 `Result`（:237,244），而 `response.deinit(alloc)`（:184）在返回前释放原 body。净效果是一份，但存在「整读入内存再处理」：`readResponse` 有 `max_body_bytes = 10 MiB`（:12）与 `BodyTooLarge`（:840,1248,1329），解码走流式 `decodeContentEncoding`（:216,268-293）。有界、可接受，仅记录。 | `http_fetch.zig:12`、`:184`、`:237`、`:244`、`:285-293` | 若要省一份，`Result.body` 可直接接管 `response.body` 的所有权（transport 侧不再 free） | 跑现有 fetch 测试并统计峰值（现有用例已覆盖 body 边界） |
| M-08 | `src/core/tooling/tool_result_limits.zig:20-69` | 双份拷贝（有界） | 观察项 | 读码确认 | `prepareModelOutputWithTruncation` 先在 scratch arena 里 sanitize+truncate，再 `alloc.dupe` 出最终副本（:66）。raw/sanitized/capped 瞬时三份，但 scratch 在函数返回时释放（:51），最终只留一份 ≤`max_bytes`（默认 64 KiB，:7）。与 §8.6 的「2–4 份瞬时副本」描述一致，量级很小。 | `tool_result_limits.zig:24-27,50-68`；`default_max_tool_result_bytes` :7 | 若要省一次拷贝，可让 sanitize 直接写进目标 buffer（需先取 prefix 再 sanitize，顺序可调换） | 对 1 MiB raw 输出跑 `prepareModelOutput`，用 `checkAllAllocationFailures` + 峰值统计 |
| M-09 | `src/core/execution/command_runner.zig:1270-1366` | 有界多份 | 观察项 | 读码确认 | `OutputCollector` 同时持有 preview（head+tail，各 ≤ 预览上限）与全量 stdout/stderr；超过 `max_command_output_bytes` 后切到 artifact 文件（`startArtifact` :1369），切点后 `clearRetainingCapacity`（:1383-1384）释放逻辑内容但保留容量。全量缓冲只在切点前无界增长，切点后即有界。 | `command_runner.zig:1107-1157`（StreamPreview 有界）、`:1274-1275`、`:1369-1384` | 切点时把 preview 容量也收缩（`deinit`+重建），或预览上限与 `max_command_output_bytes` 挂钩 | 对一个 100 MiB 输出命令跑 `executeCommand`，断言切点后 RSS 不再随输出增长 |
| M-10 | `src/mcp/server.zig:918-928` | 保留容量高水位 | 观察项 | 读码确认 | `newLogical` 对固定数组 `logical` 复用 arena（`reset(.retain_capacity)` :922），`l.* = .{...}` 整体重写（:923）使旧字段的 arena 内存随 reset 失效，无悬垂。`instance` 等短生命周期字段在同一个 arena 内重新分配。与 M-05 同性质：一次大 call 后该 logical 的 arena 高水位保持。 | `server.zig:918-928`、`:380`（deinit 逐个 arena.deinit）、`:356`（初始化） | 与 M-05 同法：大 exchange 后按阈值收缩 | 对一个带大 arguments 的 call 后再发小 call，断言 arena 容量回落 |
| M-11 | `src/mcp/engine.zig:253-270,587-623` | 已核实对称 | 干净 | 读码确认 | `Engine.call` 的 `copy` 在 `slot.calls.append` 失败时 free（:260-263），`step` 失败时 `pop().?` 后 free（:265-268）；`onServer` 的 `.called` 在 `orderedRemove` 后 `free`（:463-464）；`destroySlot` 释放 server、calls、arena（:614-623）；`deinit`/`reload`/`sweep` 全部走 `destroySlot`。无泄漏。 | `engine.zig:259-268,463-464,587-623,146-162` | 无需修 | 现有 engine 测试 + `checkAllAllocationFailures` 已覆盖（未见失败） |
| M-12 | `src/gateway/sse.zig:43-131` | 已核实有界 | 干净 | 读码确认 | `Reader` 对单事件（`max_event_bytes`）、总流（`max_total_bytes`）双上限；`data`/`line` 复用存储（:79-84 的 memmove+swap 避免第二份大 payload）；取消/EOF/超大事件各自成对返回；测试 :283-295 断言分配量 < 2×文本。 | `sse.zig:44-45,61-91,101-130`；测试 :279-295 | 无需修 | 现有 fuzz + framing 测试 |

## 3. 已验证干净的区域及理由

| 区域 | 理由（证据） |
| --- | --- |
| `src/gateway/sse.zig` | 双上限（事件/总量）、存储复用、取消/EOF/超大事件路径成对；测试断言分配量有界（:279-295）。 |
| `src/gateway/client.zig` 的 SSE 消费（:4371-4499） | `content_buf`/`replay`/`event_arena`/`streamed_tool_inputs`/`tool_accumulators` 均有 defer 释放；`finish_resolved_provider`/`generation_id`/`resolved_model`/`provider_failure_detail` 逐一手写 free（:4396-4408）；`event_arena` 每事件 reset（M-02 只谈高水位，非泄漏）。 |
| `src/gateway/client.zig` 的重试循环（:1741-1990） | 循环内 defer 覆盖 `req`/`addresses`/`host_header`/`response`/`err_out`；auth header 走 `secret.zeroAndFree`（:1713-1714）；错误 body 用 4 KiB 栈缓冲 + `streamRemaining`（:1946-1950）；连接池 drain 有界（:1995-2004）。 |
| `src/mcp/engine.zig` | Call 的 name/arguments 分配与 free 全对称（M-11）；slot arena 随 `destroySlot` 整体释放；retired 队列在 3.5 s 后强制回收（:573-585）。 |
| `src/mcp/auth/client.zig` 的密钥材料 | `free()` helper 先 `std.crypto.secureZero` 再 free 并置 null（:839-844）；`dropTokens`/`storeTokens` 覆盖 access/bearer/refresh_token 三条（:779-808）；`deinit` 先 dropTokens 再清三个 arena（:197-205）。M-04 只涉及 flow arena 的重置时机，不涉及密钥安全。 |
| `src/mcp/io/http.zig` | 每请求 slot arena 在 `claim` 重置（:223），`deinit` 逐个 `arena.deinit`（:172-184）；`budget` 限制响应体（:26,48,367,380,462）；队列遗留消息在 deinit 释放（:179-180）。 |
| `src/mcp/server.zig` | logical 数组固定、arena 复用且随 `l.*` 整体重写（M-10 只谈高水位）；outbox 的 arena 在 `unkeep`/`deinit` 释放（:378-379,1843-1850）；`instructions`/`session_id` 等 gpa 分配均有对应 free（:371-376）。 |
| `src/core/execution/command_runner.zig` | `StreamPreview` head/tail 各自有界（:1110-1151）；`OutputCollector` 超限切 artifact 文件（:1369-1384）；`startArtifact` 的 errdefer 语义经最小程序验证正确（artifact 创建失败不影响已入 self 的字段）；`createCommandArtifact` 全路径 errdefer 成对（:1890-1975）。 |
| `src/core/tooling/tool_result_limits.zig` | scratch arena 内 sanitize/truncate，最终只留一份 ≤64 KiB 的副本（:44-69）。 |
| `src/core/tooling/command_output_content.zig` | `CanonicalOutput` 的 records/transforms 在 `deinit` 逐个释放（:314-328）；`canonicalizeForegroundResult` 的 errdefer/提前返回均先 deinit（:482,501,509）。 |
| `src/tools/web/http_fetch.zig` | `fetch` 的 redirect 循环每层 defer 恰好覆盖替换后的 `current`（:143,193-194）；`decodeContentEncoding` 流式且 cap 校验（:268-293,1248,1329）；body 上限 10 MiB（:12）。 |
| `src/core/auth/auth_runtime.zig`、`src/core/auth/chatgpt_oauth.zig`、`src/core/auth/credentials.zig` 等 | 密钥材料一律 `secret.zeroAndFree` 或 `@volatileCast` + `secureZero`（auth_runtime :607,728,742,756,795,976,2839,2921,3212,3478,3832,3996；chatgpt_oauth :43,62,63,125,127,462,491,492）。 |
| `src/tools/shell/shell.zig` | 输入解析走请求级 arena（:197-243），`OwnedInput` 通过 `arena_state` 转移所有权并在 `inputDeinit` 释放；命令长度上限 64 KiB（:476）。 |
| `src/core/execution/managed_execution.zig` | Entry 的 arena 随 entry 创建/销毁成对（:217-293）；errdefer 链覆盖 route/replay_capability/output（:251-256,327）。 |
| `src/core/mcp_host/credentials.zig`、`config_file.zig`、`workspace_config.zig` | `readFileToEnd` 均带显式上限（1 MiB / `max_store_bytes` / `max_config_bytes`），读取后按 arena/gpa 归属释放。 |
| `src/core/notifications/sound.zig`、`src/core/slack/install.zig`、`src/core/upgrade/upgrade_helpers.zig` | 小文件读取（64 B / 64 KiB / 1 MiB）均有上限且调用方释放。 |

## 4. 疑似但未证实

| ID | 位置 | 疑点 | 为何未证实 | 证实方法 |
| --- | --- | --- | --- | --- |
| S-01 | `src/gateway/client.zig:4373` `GatewayReplayBuilder` | replay 是否在 `content_capture_limit != null` 时也保留全量事件（若是，则 M-01 的「双份」在有限捕获下仍成立一份） | 未读 `replay.observe` 全部实现细节，只确认了调用条件（:4478） | 读 `GatewayReplayBuilder.observe` 与 `deinit`，确认保留策略 |
| S-02 | `src/mcp/elicitation.zig`（2154 行）、`elicitation_interaction.zig`（1738 行） | 交互 slot 的 arena/answers 是否在取消路径释放 | 文件大、本轮未逐行读 | 对两文件的 `slot`/`answers` 做分配点配对 grep + 读 `deinit` |
| S-03 | `src/core/mcp_host/runtime.zig`（2954 行）的 `:2345-2380` `parseFromSliceLeaky` | 解析进谁的 arena、谁释放 | 只确认了调用点，未追调用者 | 追 `runtime.zig:2345` 的 `a` 来源到其 `deinit` |
| S-04 | `src/core/tooling/tool_admission.zig`（6484 行）、`tool_runtime.zig`（8455 行） | 大量 `alloc`/`ArrayList` 是否每条路径成对 | 密度高（144/72 处分配点），本轮只抽了与结果缓冲相关的部分 | 对两文件做「分配点→最近 errdefer/deinit」的脚本化配对检查 |
| S-05 | `src/core/auth/login_flow.zig`（2684 行）、`oauth_session.zig`（1560 行） | 长生命周期凭证缓存的刷新是否留下旧 buffer | 只看了清零规范，未逐路径追 | 追 `credentials.Credential` 的 replace 路径 |

## 5. 可量化的节省机会

| 机会 | 位置 | 预估收益 | 依据 |
| --- | --- | --- | --- |
| replay 引用化 + 设上限 | `client.zig:4373,4478` | 长输出模型请求的流期间峰值降近一半（文本不再双份保留） | M-01：每字节同时进 `content_buf` 与 `replay`；主路径 `content_capture_limit=null` |
| 流结束收缩 event arena | `client.zig:4447` | 一次 32 MiB 单事件后归还最多约 32 MiB 提交 | M-02：`retain_capacity` 保持 JSON 树高水位 |
| http slot arena 阈值收缩 | `mcp/io/http.zig:223` | 每 slot 最多归还约 16 MiB（`max_message`），slot 数 = `max_in_flight + waiting_room` | M-05 |
| mcp logical arena 阈值收缩 | `mcp/server.zig:922` | 每 logical 归还其最大 exchange 的量级 | M-10 |
| 工具结果先截后洗 | `tool_result_limits.zig:54-66` | 大结果（1 MiB 级）省一次全量 sanitize 拷贝与 scratch 峰值 | M-08：当前先 sanitize 全文再 truncate |
| command 输出切 artifact 后收缩 preview | `command_runner.zig:1383-1384` | 每条超大输出命令省 head+tail 两份预览容量 | M-09：`clearRetainingCapacity` 保留容量 |
| 线程栈/并发（§8 遗留，非本域新发现） | `main.zig:4126-4131`、`parallel_execution.zig:230-243` | 约 4.1 GiB 提交（300 线程 × 16 MiB → 2 MiB 的上界估算） | 上一轮 §8.5；本轮未重复验证，仍属实测待办 |

### 与上一轮 §8 的关系

- §8.3 的「真实泄漏：静态未发现足以解释 GB 级的候选」在本域内成立：本轮新增的 12 条中无一是 P0，全部为有界浪费或生命周期不对称。
- §8.6 提到的 `gateway/chat_completions.zig:112-157` 与 `anthropic_messages.zig:86-92,155-163` 的「每 step 序列化投影消息/tool schema/完整 request body 到独立分配」属 `src/core/agent/runtime` 与 `src/gateway/chat_completions.zig` 的交界，本轮只确认了 `content_capture_limit` 的生产默认值为 null（M-01 的调用面证据），未重复审计 chat_completions 的序列化拷贝。
- §8.10 的两项修正（线程数≠代理数、16 MiB 仅为 hint）与本域无关，维持原结论。
