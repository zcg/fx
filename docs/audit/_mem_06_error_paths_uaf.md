# 跨模块错误路径与指针安全审计（正确性向）

审计对象：D:\Projects\zigprojects\fx（Zig 0.17，std.heap.c_allocator，build.zig link_libc=true）
范围：errdefer 覆盖、分配失败测试覆盖、悬垂/UAF 模式、free 借来的内存、unmanaged/managed API 误用、Zig 0.17 迁移遗留。
方法：grep 系统扫 + 逐条读码追踪（本轮只做静态阅读，未跑 zig build/test）。
基线：docs/audit/2026-11-06-full-review.md §8（多子代理并发内存，实测 6.8 GB Private / 308 线程，结论为栈提交放大而非泄漏）。

## 1) 摘要

- 静态扫描 3244 处 errdefer、23 处 arena reset(.retain_capacity)、688 处 toOwnedSlice、1462 处 @ptrCast、34 处 unmanaged HashMap。
- 确认的真实问题 2 个（均为 P2/P3 级，无 P0/P1）：
  1. `src/core/agent/worker_runtime.zig:4679-4689` `makePrompt` 连续 5 次 `try alloc.*`，第 2 次起失败时前一次已泄漏，无 errdefer。
  2. `src/mcp/auth/client.zig:353-355` 与 `:472-479`、`:758-765` arena reset 后 `try ...dupe` 失败返回时，结构体字段仍指向已 reset arena 的旧内存（retain_capacity 下物理内存仍有效，但逻辑悬空，arena 再次分配会覆盖）。
- 上一轮 §8 的 P3 排除项「errdefer/deinit 覆盖 admission clone 与 ActiveWork」在本轮复核中维持原结论：覆盖完整，未发现遗漏。
- 分配失败测试覆盖：agent runtime、session、gateway、terminal、acp、permissions、input、tooling 已有 FailingAllocator/checkAllAllocationFailures 覆盖；session_manager、core/gateway、core/output、core/hosts、core/cli 零覆盖，是最大缺口。
- 悬垂/UAF 高危模式（realloc 后旧指针、HashMap value 指针失效、free 后使用、double free、闭包捕获释放内存）本轮未发现确认实例；所有候选读码后均为安全模式（所有权转移、swapRemove 后不再解引用、arena 内 reset 前重新赋值）。

## 2) 发现表

| ID | file:line | 类型 | 严重度 | 置信度 | 机制 | 证据 | 修法 | 证实方法 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F-01 | src/core/agent/worker_runtime.zig:4679-4689 | errdefer 缺失（多分配） | P2 | 读码确认 | `makePrompt` 连续 `try alloc.dupe`（text/model/api_key）+ `try alloc.alloc`（history/grants）共 5 次分配；第 2 次失败时第 1 次结果已泄漏，无任何 errdefer | `fn makePrompt` 返回前 `.prompt = try alloc.dupe(u8, text)` … `.history = try alloc.alloc(...)`，函数体内无 errdefer；同文件 `makeImagePrompt`（4690-4691）反而有 `errdefer freeQueuedPrompt`，说明作者知道该模式但 makePrompt 漏了 | 在 `.prompt` 分配后加 `errdefer alloc.free(prompt_text)` 风格，或先全部 dupe 到局部再组装；最简：把 5 次分配改为 `try` 局部变量 + 统一 errdefer 释放 | `std.testing.checkAllAllocationFailures(testing_allocator.no_resize, makePrompt, .{...})` 跑通即修复 |
| F-02 | src/mcp/auth/client.zig:353-355 | arena reset 后字段悬空（OOM 时） | P2 | 疑似（需运行时证实） | `signIn` 先 `_ = a.flow_arena.reset(.retain_capacity)`，再 `a.redirect_uri = try a.flow_arena.allocator().dupe(u8, redirect_uri)`；dupe 抛 OOM 时函数返回 error，但 `a.redirect_uri` 仍指向旧 arena 内存；后续 `finishSignIn`/`writeRegistration`/`writeTokenRequest`（583/603/627 行）读 `a.redirect_uri` 即逻辑 UAF | 355 行 `a.redirect_uri = try a.flow_arena.allocator().dupe(...)` 是 reset 后第一次赋值；`redirect_uri` 字段默认 `""`（154 行），reset 前若已有值则变悬空 | reset 前先把 `a.redirect_uri = ""`（或把 dupe 提到 reset 前成功后再 reset）；或在 dupe 失败分支显式 `a.redirect_uri = ""` | 用 FailingAllocator 在 dupe 处注入 OOM，随后调用 `finishSignIn` 观察是否读到 stale 指针 |
| F-03 | src/mcp/auth/client.zig:472-479, 758-765 | 同源：cred_arena reset 后 `a.cred` 字段悬空（OOM 时） | P3 | 疑似 | `keepCredential` 先 `_ = a.cred_arena.reset(.retain_capacity)`，再 `a.cred = .{ .token_endpoint = try ca.dupe(...) }`；任一 dupe 失败时 `a.cred` 部分字段指向已 reset 内存 | 472-479 行 reset 后 4 个 `try ca.dupe`；758-765 行同模式 | 同 F-02：失败分支重置 `a.cred = .{}` 或先 dupe 成功再 reset | FailingAllocator 注入 + 后续读 `a.cred.token_endpoint` |
| F-04 | src/core/session/session_adapter.zig:1695-1749（commitTurn） | 疑似 errdefer 缺口（实为安全） | P3 | 读码确认安全 | 函数内 5+ 次 `try` 分配，但全部用局部 `arena`（commitTurn 开头 `ArenaAllocator.init(self.alloc)` + `defer arena.deinit()`），OOM 时 arena 整体释放，无泄漏 | 1699-1702 行 arena 初始化；所有分配用 `a`（arena allocator），仅最后 `self.alloc.dupe(u8, language_tag)`（1746）有 `if (self.language) |old| free` 前置保护 | 无需修；如需更清晰可把最后的 language dupe 提到锁外 | 分配失败 sweep（当前无） |
| F-05 | src/core/agent/runtime/tool_presentation.zig:437-470 | 疑似悬垂（实为安全） | P3 | 读码确认安全 | `finishTrackedCancelled` 循环体取 `&self.tracked.items[len-1]` 后调用 `self.forget(alloc, status.id)`（内部 swapRemove）；`status` 指针在 forget 后不再解引用，且 forget 移除的正是该 index | 438 行取指针；441/447/466 行 `self.forget(...)` 后均 `continue` 或进入下一轮迭代，不再用 `status` | 无需修 | 若要保险可加注释说明 |
| F-06 | src/acp/server.zig:421-422 vs 833 | allocator 不匹配（实为一致） | P3 | 读码确认安全 | `report_calls` 在 `postAcpReport` 内用 `std.heap.c_allocator`（821 行 `const alloc = std.heap.c_allocator`）append，deinit 也用 c_allocator | 833 行 `state.report_calls.append(alloc, call)` 的 alloc 来自 821；421-422 行 deinit 同样 c_allocator | 无需修 | — |
| F-07 | src/core/shared/sort_utils.zig 与 11 处 `std.mem.sort` | Zig 0.17 迁移遗留 | P3 | 读码确认 | AGENTS.md 规定用项目 `sort_utils.sort` 替代 `std.mem.sort`；indexer/session_manager/io-only 文件除外。`src/core/compactor/records.zig:857`、`src/core/gateway/model_catalog.zig:926`、`src/core/mcp_host/mcp_call.zig:422-423`、`src/core/permissions/session_permission_state.zig:300`、`src/core/session_manager/catalog.zig:613`、`src/core/session_manager/session.zig:3717`、`src/core/shared/fuzzy_match.zig:723`、`src/core/shell_command/command_effect.zig:2317` 仍用 `std.mem.sort` | sort_utils 是稳定排序且共享实现；std.mem.sort 是不稳定排序。records.zig 的 `Doc.better` 若依赖相等元素相对顺序，行为可能不同 | 非 indexer/session_manager 文件改用 `sort_utils.sort`；先确认比较器是否要求稳定 | 对相等键元素跑排序前后顺序对比测试 |
| F-08 | src/core/indexer/scan.zig:273,582、src/core/session_manager/session.zig:3717 | std.mem.sort 合规（边界内） | P3 | 读码确认安全 | AGENTS.md 明确 indexer/session_manager 可保留 std.mem.sort | scan.zig 属 indexer；session.zig 属 session_manager | 无需修 | — |

## 3) 已验证干净的区域及理由

- **arena reset 循环模式（orchestrator.zig:7157、session_adapter.zig:3812/4591/4599、session_log.zig:911/1113/1193/1214、session_manager/session.zig:1415/1854/1863/1896/2024/2077、gateway/client.zig:4447、mcp/io/http.zig:223、mcp/server.zig:922）**：reset 均在循环开头，reset 后立即用新 allocator 重新赋值；跨迭代存活的列表（history/turns/encoded）用普通 alloc 而非 arena，reset 不影响。
- **`deinit(arena)` 系列（orchestrator.zig:5756-5879 等 30+ 处）**：Zig 0.17 ArrayList.deinit(allocator) 对 arena 是 free-no-op，语义安全。
- **HashMap getPtr 覆写（subagent/tool_call_identities.zig:85、compactor/records.zig:296、config/settings_store.zig 全部）**：getPtr 后先 free 旧值再 `existing.* = owned`，put/remove 不与已取指针并发；settings_store 的 getPtr 全在 std.json.Value 树上（对象 put 不使兄弟指针失效）。
- **`&self.entries.items[idx]` 后调用 append（question_prompt.zig:411-691 共 18 处）**：entries 仅在 init 时 `appendAssumeCapacity`（266 行），运行期不 append/remove，元素指针稳定；`freeformInsert`/`advanceOnDecision` 只改 options/freeform_buffer 子列表。
- **tool_presentation.zig forget/swapRemove（639-651）**：forget 内 `deinit` 后 swapRemove，调用点（441/447/466）随后 continue 或进入下一迭代，不在 swapRemove 后解引用旧指针。
- **realloc 链（oauth.zig:534、bounded_read.zig:89、js_host_workspace.zig:365、tool_search.zig:412、command_replay_store.zig:130、process_tree.zig:267）**：均为 `buf = try alloc.realloc(buf, n)` 标准形态，旧指针在 realloc 返回前不再使用。
- **@ptrCast 回调上下文（acp/prompt.zig 20+ 处、server.zig:1345、permission_reviewer.zig:215/407、typesafe_permission_reviewer.zig:133/433）**：均为 ACP/JSON-RPC FFI `*anyopaque` 回转或 `alloc.create(Owned*)` 所有权转移配 `deinit_fn`；typesafe 的 `&config` 是栈局部但 reviewer 同步使用不逃逸。
- **@ptrFromInt（io.zig:1353、json_decode.zig:662、windows_shell.zig:293-294、app_commands.zig:1901）**：Windows pid 不透明句柄注释明确无调用者到达；json_decode 是空切片对齐 trick；HKEY 是常量句柄。
- **libfx_journal.zig:419 free(tool.data) / libfx_steering.zig:415-519 free 链**：free 的都是 history_alloc/result_alloc 拥有的拷贝，free 后立即置 null 或写新值，无 use-after-free。
- **mem_utils.zig 统一 free/deinit_arena**：项目级清理入口，减少逐点 errdefer 需求。
- **errdefer 密度**：session_codec.zig 125、types.zig 94、worker_runtime.zig 77、session_json.zig 71、session_adapter.zig 69、terminal/store.zig 65、transcript/store.zig 48 等热点文件 errdefer 与分配点密度匹配，未发现系统性遗漏。

## 4) 分配失败测试覆盖缺口清单（按模块）

已有覆盖（文件数/总文件数，含 checkAllAllocationFailures 或 FailingAllocator）：

| 模块 | 覆盖 | 缺口说明 |
| --- | --- | --- |
| src/core/agent | 20/54 | orchestrator、worker_runtime、assistant_stream、execution_memory、tool_preparation、parallel_execution、cache_warmer、journal、lifecycle、prompt_context 已有；剩余 34 文件多为小类型/纯逻辑 |
| src/core/session | 9/34 | session_codec/session_json/session_adapter/session_log 已有；session.zig 本体无 |
| src/gateway | 7/31 | client.zig 已有；anthropic_messages/chat_completions 等协议文件无 |
| src/ui | 13/88 | transcript 三件套已有；footer/viewport、render_engine 大部分无 |
| src/acp | 4/14 | server.zig 有 checkAllAllocationFailures；prompt.zig 有 FailingAllocator；jsonrpc/libfx_hooks 有 |
| src/core/permissions | 4/12 | auto_classifier 相关有 |
| src/core/input | 9/31 | file_picker_path 等有 |
| src/core/tooling | 9/35 | — |
| src/core/terminal | 8/13 | engine/store 有 |
| src/core/mcp | 10/24 | — |
| src/core/app | 7/41 | app_session_runtime/input_submit_runtime 有 |
| src/core/auth | 3/21 | login_flow/oauth 有 |
| src/builtins | 4/14 | context/mcp/skills/gateway 有 |
| src/core/config | 2/15 | config_runtime 有 |
| src/core/compactor | 1/10 | 仅 1 文件 |
| src/core/workspace | 5/22 | — |
| src/core/images | 2/5 | — |
| src/core/skills | 2/4 | — |
| src/core/indexer | 1/11 | 仅 scan（且 indexer 受边界约束，alloc 少） |
| src/core/cli | 1/11 | — |
| src/core/execution | 1/10 | — |
| src/core/shared | 3/38 | testing_allocator/sort_utils/json_decode 有自测 |

零覆盖模块（按分配点数量排序，均为缺口）：

| 模块 | 文件数 | 分配点（try alloc/dupe/append 估算） | 风险说明 |
| --- | --- | --- | --- |
| src/core/session_manager | 10 | 42（session.zig 单文件） | 会话恢复/折叠/fork 核心路径，OOM 时行为未验证 |
| src/core/output | 10 | 37 | 输出契约文本/JSON 快照，OOM 可能丢字段 |
| src/core/hosts | 18 | 21 | ACP/JS host 桥接，OOM 时回调语义未验证 |
| src/core/gateway | 6 | — | 模型目录/协议解析 |
| src/core/cli | 11 | — | CLI 参数解析 OOM 路径 |
| src/mcp | 31 | — | MCP 引擎（src/mcp 与 src/core/mcp 分工不同） |

优先补齐建议：session_manager/session.zig（42 分配点 + 会话正确性关键）、core/output（输出契约）、worker_runtime.makePrompt（F-01 直接对应）。

## 5) 疑似但未证实

- **F-02/F-03 的实际触发率**：arena reset 后 dupe 失败只在 OOM 时发生，且 retain_capacity 下旧内存物理仍有效，是否真正造成可观测错误需运行时证实（VMMap/UMDH 或 FailingAllocator 注入）。
- **§8.5 P0 三项（线程栈/并发上限/并行工具线程）与本轮错误路径域的交叉**：parallel_execution.zig 每工具调用一线程 + 一 arena，若 arena reset 与线程退出顺序错乱可能 UAF，但本轮未深入并发行（属 §8 域），仅标记。
- **sort_utils 稳定性差异（F-07）**：records.zig `Doc.better`、model_catalog `compareModelCatalogEntries` 是否依赖相等元素顺序未逐字验证比较器语义，需读比较器确认。
- **tool_presentation finishUnmatchedRecoveryStarts（534-570）**：与 finishTrackedCancelled 同模式但 index 递减，swapRemove 把末尾元素移到当前 index，递减循环不碰已访问区——推断安全，未逐行验证 swapRemove 后 `status` 指针的所有解引用点。
- **gateway/client.zig:4447 `defer event_arena.reset` 在 SSE 循环内**：事件数据在迭代内消费完，但 `captureGenerationMetadata` 是否把 arena 指针存入跨迭代状态未追到底。
- **ACP prompt.zig 大量 @ptrCast(self) 回调**：AcpContext 生命周期与会话绑定，未发现提前释放路径，但线程（ActivePrompt.thread）与 deinit 的 join 顺序未验证。
