```text
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

# fx

<div align="center">

**[English](#english) · [中文](#中文)**

</div>

<a id="english"></a>

## English

fx is a small, native coding agent. This fork focuses on making the agent feel at home on Windows while keeping the original Unix-like terminal workflow.

### What this fork adds

- **Windows as a first-class target.** The fork improves Windows shell handling, native credential storage, git discovery, path handling, file operations, and terminal rendering.
- **Native terminal workflow.** fx prints into your terminal scrollback instead of taking over the screen, so scrolling, searching, copying, and tmux bindings keep working.
- **One small agent core.** fx is a single Zig binary and can be used as a CLI, through ACP, or through the libfx JavaScript SDK.

### Quick start

```bash
fx
fx ask "explain this repository"
fx ask --json "summarize the failing tests"
```

The upstream project documentation lives at [fx.sh/docs](https://fx.sh/docs). This fork tracks the upstream code from `vercel-labs/fx` with additional Windows-focused work.

<a id="中文"></a>

## 中文

fx 是一个小巧的原生编码代理。这个分支专注于改善 Windows 下的使用体验，同时保留原项目 Unix 风格的终端工作流。

### 这个分支的主要工作

- **Windows 一等公民适配。** 改进了 Windows 下的 shell 处理、系统凭据存储、git 查找、路径与文件操作，以及终端渲染。
- **原生终端工作流。** fx 直接把对话输出到终端 scrollback，不独占整个屏幕，因此可以正常滚动、搜索、复制，也能继续使用 tmux 绑定。
- **统一的小型代理核心。** fx 是单个 Zig 二进制，可以作为 CLI 使用，也可以通过 ACP 或 libfx JavaScript SDK 接入其他工具。

### 快速开始

```bash
fx
fx ask "explain this repository"
fx ask --json "summarize the failing tests"
```

上游项目文档见 [fx.sh/docs](https://fx.sh/docs)。本分支基于 `vercel-labs/fx` 的上游代码，并加入了面向 Windows 的适配工作。
