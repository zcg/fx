//! Adds a Windows skip to test blocks that use POSIX-only declarations.
//!
//! A test that calls `std.posix.SIG.KILL`, `sigaction`, `poll`, `kill`, or names
//! a `posix.fd_t` models POSIX behavior. None of it exists on Windows, so the
//! block does not compile there. Rather than gate every statement, the block gets
//! one line at its top: it reports itself skipped and returns before any of the
//! POSIX code is reached. Windows coverage is added as separate tests written
//! against Windows behavior.
//!
//! Usage: node add_windows_skips.js <file> [<file> ...]

const fs = require("fs");

const POSIX_MARKERS = [
  "std.posix.SIG.",
  "std.posix.Sigaction",
  "std.posix.sigaction",
  "std.posix.kill",
  "std.posix.poll",
  "std.posix.fd_t",
  "std.posix.termios",
  "std.posix.tcgetattr",
  "std.posix.tcsetattr",
  "std.posix.winsize",
  "std.posix.socket_t",
  "std.posix.mode_t",
  "std.posix.system.",
  "std.posix.pipe",
  "std.posix.errno",
  "std.c.SIG",
  "std.c.kill",
  "std.c.waitpid",
  "std.c.getpid",
  "std.c.isatty",
  "std.c.poll",
  "std.c.socketpair",
  "std.c.fcntl",
  "std.c.dup",
  "std.c.readlink",
  "std.c.realpath",
  "std.c.mkdir",
  "std.c.access",
  "std.c.environ",
  "std.c.lseek",
  "std.c.time_t",
  "forkpty",
  "openpty",
  "posix.sockaddr",
];

const SKIP_LINE =
  '    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;\n';

function lineStarts(src) {
  const starts = [0];
  for (let i = 0; i < src.length; i++) if (src[i] === "\n") starts.push(i + 1);
  return starts;
}

function braceBody(src, openIndex) {
  // Returns the index just past the matching close brace.
  let depth = 0;
  let i = openIndex;
  let inString = false;
  let inLineComment = false;
  let inBlockComment = false;
  let stringQuote = "";
  while (i < src.length) {
    const c = src[i];
    const next = src[i + 1];
    if (inLineComment) {
      if (c === "\n") inLineComment = false;
      i++;
      continue;
    }
    if (inBlockComment) {
      if (c === "*" && next === "/") {
        inBlockComment = false;
        i += 2;
        continue;
      }
      i++;
      continue;
    }
    if (inString) {
      if (c === "\\") {
        i += 2;
        continue;
      }
      if (c === stringQuote) inString = false;
      i++;
      continue;
    }
    if (c === "/" && next === "/") {
      inLineComment = true;
      i += 2;
      continue;
    }
    if (c === "/" && next === "*") {
      inBlockComment = true;
      i += 2;
      continue;
    }
    if (c === '"' || c === "'") {
      inString = true;
      stringQuote = c;
      i++;
      continue;
    }
    if (c === "{") depth++;
    if (c === "}") {
      depth--;
      if (depth === 0) return i + 1;
    }
    i++;
  }
  return -1;
}

function processFile(path) {
  let src = fs.readFileSync(path, "utf8");
  const lines = lineStarts(src);
  const inserts = [];

  for (let n = 0; n < lines.length; n++) {
    const lineStart = lines[n];
    const lineEnd = n + 1 < lines.length ? lines[n + 1] : src.length;
    const line = src.slice(lineStart, lineEnd);
    if (!/^test "/.test(line)) continue;

    // Find this test's body.
    let openIndex = src.indexOf("{", lineStart);
    if (openIndex < 0 || openIndex > lineEnd) continue;
    const endIndex = braceBody(src, openIndex);
    if (endIndex < 0) continue;
    const body = src.slice(openIndex, endIndex);

    const usesPosix = POSIX_MARKERS.some((marker) => body.includes(marker));
    if (!usesPosix) continue;
    if (body.includes("SkipZigTest") && body.includes(".windows")) continue;

    // Insert right after the opening brace's line.
    const insertAt = src.indexOf("\n", openIndex) + 1;
    if (insertAt <= 0) continue;
    inserts.push(insertAt);
  }

  if (inserts.length === 0) return 0;

  inserts.sort((a, b) => b - a);
  let out = src;
  let added = 0;
  for (const at of inserts) {
    out = out.slice(0, at) + SKIP_LINE + out.slice(at);
    added++;
  }
  fs.writeFileSync(path, out);
  return added;
}

let total = 0;
for (const file of process.argv.slice(2)) {
  try {
    const added = processFile(file);
    if (added > 0) {
      console.log(`${file}: +${added}`);
      total += added;
    }
  } catch (err) {
    console.error(`${file}: ${err.message}`);
  }
}
console.log(`total: ${total}`);
