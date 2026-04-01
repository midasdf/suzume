# ZeroCode Design Spec

**Date**: 2026-04-02
**Status**: Draft
**Binary**: `zerocode`
**Reference**: [instructkr/claw-code](https://github.com/instructkr/claw-code) (Rust, ~22,000 LOC)

## Goal

Rewrite claw-code (a standalone Claude Code reimplementation) in Zig for personal use. The primary motivation is eliminating Node.js runtime dependency and its unbounded RSS growth. Zig's explicit memory management with arena allocators provides deterministic memory reclamation that Node.js GC cannot achieve.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Modular monolith | Clear mapping to claw-code crates, single build.zig |
| API providers | Anthropic only (initially) | Extensible via Provider interface for future OpenAI-compat |
| MCP transports | All 4 (stdio, SSE, HTTP, WebSocket) | Full feature parity from day one |
| Plugin system | Full (hooks + plugin management) | Heavy hook/skill usage in current workflow |
| Syntax highlight | Tree-sitter (C link) | Lighter than syntect, Zig cimport natural fit |
| Regex (Grep) | Native fixed-string + rg/grep fallback | No std regex in Zig, avoids heavy PCRE2 dep |
| HTTP/TLS | std.http.Client + std.http.Server | Zero external dependency |
| Terminal | std.posix.termios + ANSI | Zero external dependency |
| Reference impl | claw-code Rust source | Follow its patterns when design decisions are ambiguous |

## Memory Architecture

The core design advantage over Node.js. Three-tier arena allocator strategy:

```
Persistent Allocator (GeneralPurposeAllocator)
  - Process lifetime: CLI config, history file paths, signal state
  - Tiny footprint, supports individual free() for config updates
  - Backed by page allocator (mmap/munmap)

  └── Session Allocator (ArenaAllocator)
        - Lifetime: one session (reset on /clear, session switch)
        - Holds: conversation history, plugin registry, MCP client state,
                 session config, permission rules
        
        └── Turn Allocator (ArenaAllocator)
              - Lifetime: one user message → response complete
              - Holds: API response parsing, tool execution intermediates,
                       JSON serialization, SSE frame buffers
              - Reset via .free_all on turn completion
              - This is where Node.js leaks — we reclaim deterministically
```

Why this fixes the RSS bloat:
- Node.js V8 GC is conservative; old-gen objects survive major GC cycles and RSS never returns to baseline
- Turn allocator uses `.free_all` (not `.retain_capacity`) so the backing page allocator calls `munmap`, returning physical pages to the kernel immediately. RSS drops after each turn
- `.retain_capacity` would keep pages committed (no `MADV_DONTNEED` call in ArenaAllocator). We explicitly choose `.free_all` to guarantee RSS reclamation at the cost of re-allocation on the next turn — acceptable since turn allocation patterns are predictable and the allocator warms up within 1-2 API calls
- Session allocator uses `.retain_capacity` (session lifetime is long, re-alloc cost not worth it; RSS is bounded by session high-water mark)
- LCC's recycle hack (kill and restart claude process every N turns) becomes unnecessary

## Module Structure

```
zerocode/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig              # Entry point, arg parsing, REPL loop
│   ├── api/
│   │   ├── client.zig        # AnthropicClient, Provider interface
│   │   ├── streaming.zig     # SSE parser + stream events
│   │   ├── types.zig         # MessageRequest/Response, ToolDefinition, ContentBlock
│   │   ├── auth.zig          # API key + OAuth PKCE flow
│   │   └── retry.zig         # Exponential backoff retry
│   ├── runtime/
│   │   ├── conversation.zig  # Main agent loop (heart of the system)
│   │   ├── config.zig        # Settings loader (JSON merge from multiple sources)
│   │   ├── session.zig       # Session save/restore/list
│   │   ├── permissions.zig   # Permission modes + tool allow/deny
│   │   ├── prompt.zig        # System prompt builder + CLAUDE.md/ZEROCODE.md discovery
│   │   ├── compact.zig       # Context compaction (summarize old messages)
│   │   ├── hooks.zig         # Pre/PostToolUse hook execution
│   │   ├── sandbox.zig       # Linux namespace sandboxing for Bash
│   │   └── usage.zig         # Token usage tracking + cost calculation
│   ├── tools/
│   │   ├── registry.zig      # ToolRegistry: definition + dispatch
│   │   ├── bash.zig          # Bash execution (sandbox integration)
│   │   ├── file_ops.zig      # Read, Write, Edit, Glob, Grep
│   │   ├── web.zig           # WebFetch, WebSearch
│   │   ├── notebook.zig      # NotebookEdit
│   │   ├── agent.zig         # Agent tool (subprocess self-invocation)
│   │   ├── lsp_tool.zig      # LSP tool
│   │   └── misc.zig          # TodoWrite, Skill, Config, ReplExecute
│   ├── mcp/
│   │   ├── client.zig        # MCPClient: transport abstraction
│   │   ├── protocol.zig      # JSON-RPC 2.0 messaging
│   │   ├── stdio.zig         # stdio transport (process spawn)
│   │   ├── sse.zig           # SSE transport
│   │   ├── http.zig          # Streamable HTTP transport
│   │   ├── websocket.zig     # WebSocket transport
│   │   └── discovery.zig     # Tool/resource discovery + registry registration
│   ├── plugins/
│   │   ├── manager.zig       # PluginManager: lifecycle management
│   │   ├── registry.zig      # Plugin tool registration + discovery
│   │   ├── hooks.zig         # Hook execution engine
│   │   ├── bundled.zig       # Bundled plugins
│   │   └── install.zig       # External plugin install/update/remove
│   ├── commands/
│   │   ├── registry.zig      # SlashCommandRegistry + dispatch
│   │   └── builtins.zig      # All slash command implementations
│   ├── lsp/
│   │   ├── client.zig        # LSP JSON-RPC client
│   │   ├── manager.zig       # LspManager: language→server routing
│   │   └── types.zig         # LSP type definitions
│   └── render/
│       ├── markdown.zig      # Markdown parser + terminal rendering
│       ├── syntax.zig        # Tree-sitter syntax highlighting
│       └── terminal.zig      # ANSI control, spinner, prompt, input
└── tests/
    ├── api_test.zig
    ├── streaming_test.zig
    ├── tools_test.zig
    ├── mcp_test.zig
    ├── session_test.zig
    └── fixtures/
```

## Module Details

### api/ — Anthropic API Client

**client.zig**:
- `std.http.Client` based, zero external HTTP dependency
- Messages API (`POST /v1/messages`) with `stream: true`
- Headers: `anthropic-version`, `x-api-key`, `anthropic-beta`
- `Provider` interface for future multi-provider support:
  ```zig
  const Provider = struct {
      sendMessageFn: *const fn (self: *Provider, request: MessageRequest, alloc: Allocator) Error!StreamReader,
      cancelFn: *const fn (self: *Provider) void,
      modelListFn: *const fn (self: *Provider) []const ModelInfo,
      ctx: *anyopaque,
  };
  ```
- `StreamReader`: iterator that yields `StreamEvent` (text_delta, tool_use_start, tool_input_delta, tool_use_stop, message_stop, error)
- Retry logic lives in `retry.zig`, wraps Provider — Provider itself does not retry
- Only Anthropic implementation initially; OpenAI-compat addable as another Provider

**streaming.zig**:
- SSE frame parser: `event:`, `data:`, empty line delimiter
- Events: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`
- All parse output allocated on turn allocator → freed on turn reset

**auth.zig**:
- Priority: `ANTHROPIC_API_KEY` env var → OAuth PKCE
- OAuth flow: `/oauth/authorize` → local HTTP callback server (`std.http.Server` on localhost ephemeral port) → `/oauth/token`
- Token storage: `~/.zerocode/auth.json`, auto-refresh on expiry

**retry.zig**:
- Exponential backoff with jitter for 429/5xx responses
- Configurable max retries (default 3)
- Respects `Retry-After` header

### runtime/ — Core Runtime

**conversation.zig (heart of the system)**:
1. Add user message to conversation history
2. Send streaming request to API
3. Parse response into text + tool_use blocks
4. For each tool_use: permission check → PreToolUse hook → execute tool → PostToolUse hook
5. Add tool_result to history, loop until no tool calls
6. Turn allocator reset

Reference: claw-code `runtime/src/conversation.rs` (~26KB)

**config.zig**:
- Merge order: `~/.zerocode/settings.json` → `.zerocode/settings.json` → `.zerocode/settings.local.json`
- JSON merge semantics (following claw-code):
  - Objects: deep merge (later values override earlier for same key)
  - Arrays: replace (later array replaces earlier, no concatenation)
  - Explicit `null` value: deletes the key from merged result
  - Scalars: later value wins
- Discovers both `CLAUDE.md` and `ZEROCODE.md` (walks up directory tree)

Reference: claw-code `runtime/src/config.rs` (~40KB)

**session.zig**:
- Storage: `~/.zerocode/sessions/{session_id}.json`
- `--continue` resumes latest, `--resume {id}` resumes specific
- Index file `~/.zerocode/sessions/index.json`: maps session_id → {name, model, updated_at, cwd}
  - Updated atomically (write tmp + rename) on session save
  - Rebuilt from session files on startup if missing or corrupt
  - Avoids O(n) JSON file scanning for session listing

**permissions.zig**:
- Three levels: `ReadOnly` < `WorkspaceWrite` < `DangerFullAccess`
- Default tool → permission mapping:
  - `ReadOnly`: Read, Glob, Grep, WebFetch, WebSearch, LSP (read-only ops)
  - `WorkspaceWrite`: Write, Edit, NotebookEdit (file modifications within cwd)
  - `DangerFullAccess`: Bash, Agent (arbitrary command execution, subprocess spawn)
- Per-tool allow/deny rules with glob support (`Bash(git:*)`) override defaults
- Prompter callback for user Y/N confirmation when permission insufficient

**compact.zig**:
- Triggers when estimated context tokens exceed 80% of model's context window (default 200K for Claude)
- Token estimation: character count / 3.5 heuristic (no tokenizer dependency; good enough for threshold)
- Preserves most recent 10 messages verbatim (configurable via `compactKeepMessages` in settings)
- Older messages summarized via single API call with compact system prompt
- Builds new history on session allocator, old session allocator freed via `.free_all` then re-initialized

**sandbox.zig**:
- Approach: `std.process.Child` spawns a wrapper that calls `unshare(CLONE_NEWNS|CLONE_NEWNET)` then `exec`s the actual command
  - `CLONE_NEWPID` not used (cannot unshare PID namespace for self; only affects children of clone, and we want to keep std.process.Child for simplicity)
  - `CLONE_NEWNS`: mount namespace isolation (prevent access outside cwd)
  - `CLONE_NEWNET`: network isolation (no outbound connections from sandboxed bash)
- Requires `CAP_SYS_ADMIN` or user namespaces enabled (`/proc/sys/kernel/unprivileged_userns_clone`)
- Fallback: if namespace creation fails, run unsandboxed with warning (same behavior as claw-code)
- cwd restriction via `pivot_root` or bind mount within the new mount namespace

Reference: claw-code `runtime/src/sandbox.rs`

### tools/ — Tool Definitions and Execution

**registry.zig**:
- Unified interface: `fn execute(alloc: Allocator, params: json.Value, context: *ToolContext) ToolResult`
- `ToolContext`: references to conversation state, permissions, cwd
- JSON Schema parameter definitions (sent to API as tool definitions)
- Plugin/MCP tools register into the same registry

**bash.zig**:
- `std.process.Child` command execution
- Timeout support (default 120s, max 600s)
- Sandbox integration via sandbox.zig
- stdout/stderr capture with size limits

**file_ops.zig**:
- Read: file reading with line numbers, offset/limit
- Write: file writing (overwrite existing)
- Edit: exact `old_string` → `new_string` replacement, `replace_all` support
- Glob: `std.fs.Dir` walk-based, hand-rolled glob matcher supporting `*`, `**`, `?`, `{a,b}` brace expansion, `[abc]` character classes
- Grep: native fixed-string fast search, regex falls back to `rg` subprocess (then `grep` if rg unavailable)

**web.zig**:
- WebFetch: `std.http.Client` GET/POST, response size limit
- WebSearch: delegates to configured search provider

**agent.zig**:
- Sub-agent = self-invocation via `std.process.Child`
- Independent session via `--session-id`
- Worktree support: `git worktree add` for isolated copy

Reference: claw-code `tools/src/lib.rs` (~157KB)

### mcp/ — Model Context Protocol

**client.zig**:
- Transport abstraction: function pointer table (`sendFn`, `recvFn`, `closeFn`)
- Config from `mcpServers` in settings.json or `--mcp-config`

**protocol.zig**:
- JSON-RPC 2.0: `initialize` → `tools/list` → `tools/call` lifecycle
- Request ID management (atomic counter)
- Notification send/receive (`notifications/initialized` etc.)

**stdio.zig**:
- Spawn MCP server process via `std.process.Child`
- JSON-RPC over stdin/stdout
- Process lifecycle:
  - Startup: spawn process, send `initialize`, wait for response (timeout 30s)
  - Health check: periodic `ping` request (every 60s), expect response within 5s
  - Restart: exponential backoff (1s, 2s, 4s, 8s, max 60s), max 5 attempts before marking server as dead
  - Graceful shutdown: send `shutdown` notification, SIGTERM after 5s, SIGKILL after 10s
- Concurrent management of multiple MCP servers (each server is an independent process)

Reference: claw-code `runtime/src/mcp_stdio.rs` (~62KB)

**sse.zig**:
- `std.http.Client` SSE endpoint connection
- Server→client: SSE stream; client→server: HTTP POST

**http.zig**:
- Streamable HTTP (latest MCP spec)
- Single endpoint request/response with session ID

**websocket.zig**:
- From-scratch WebSocket client implementation (Zig std has no WebSocket support)
- HTTP/1.1 upgrade handshake via `std.http.Client`
- RFC 6455 frame parser: text/binary frames, masking, ping/pong, close handshake, fragmentation reassembly
- Estimated ~600-800 LOC
- Bidirectional JSON-RPC over the WebSocket connection

**discovery.zig**:
- Parse `tools/list` response, register into ToolRegistry
- MCP tool JSON Schema → ZeroCode ToolDefinition conversion
- Tool re-registration on server restart

### plugins/ — Plugin System

**manager.zig**:
- Discovery paths: `~/.zerocode/plugins/` + `--plugin-dir` + project-local
- Plugin definition: directory with `manifest.json` (name, version, tool defs, hook defs)
- Lifecycle: discover → load → initialize → active → shutdown
- Managed on session allocator (full cleanup on session switch)

**hooks.zig**:
- PreToolUse: shell command before tool execution
  - exit 0 = allow, exit 2 = deny, other = warn and continue
  - stdin: JSON with tool name + parameters
- PostToolUse: shell command after tool execution
  - stdin: JSON with tool name + parameters + result
- `std.process.Child` execution with timeout (default 10s)
- Compatible with claw-code `settings.json` hooks format

**install.zig**:
- `zerocode plugin install <url/path>`
- Git repo or local directory copy
- `manifest.json` validation
- `zerocode plugin list/remove/update`

Reference: claw-code `plugins/src/lib.rs` (~96KB)

### commands/ — Slash Commands

**builtins.zig**:
- Full set: `/help`, `/status`, `/compact`, `/model`, `/permissions`, `/clear`, `/cost`, `/resume`, `/config`, `/memory`, `/init`, `/diff`, `/version`, `/export`, `/session`, `/agents`, `/skills`, `/plugins`
- Unified interface: `fn execute(args: []const u8, context: *AppContext) !void`

Reference: claw-code `commands/src/lib.rs` (~87KB)

### lsp/ — LSP Integration

**client.zig**:
- stdio JSON-RPC with Content-Length framing (shared structure with MCP stdio)
- `initialize` → `textDocument/definition` → `textDocument/references` → `textDocument/diagnostic`

**manager.zig**:
- File extension → LSP server routing
- Config: `lspServers` in settings.json
- Lazy startup: server process only spawned when tool is actually called

**types.zig**:
- Hand-written minimal types: `Position`, `Range`, `Location`, `Diagnostic`, `SymbolInformation`
- Only what the LSP tool actually uses (not the full LSP protocol)

Reference: claw-code `lsp/` crate

### render/ — Terminal Rendering

**markdown.zig**:
- Based on existing LCC `markdown.zig`, extended
- Code blocks, headings, lists, bold/italic, links
- Streaming: incremental rendering per chunk

**syntax.zig**:
- Tree-sitter C-linked via Zig cimport
- Languages: zig, rust, python, javascript/typescript, go, solidity, bash, json, toml, yaml, sql, markdown
- Build strategy: grammar C sources vendored under `deps/tree-sitter-grammars/`, each compiled as a static C library step in `build.zig` and linked into the binary. No shared objects, no runtime downloads
- Tree-sitter core library also vendored under `deps/tree-sitter/`

**terminal.zig**:
- Based on existing LCC `terminal.zig`, extended
- Raw mode, alternate screen, cursor control via `std.posix.termios` + ANSI escapes
- Readline-style line editing, history, multiline input
- Spinner animation during tool execution

### main.zig — Entry Point

- Argument parsing: manual (no external dep), same approach as LCC
- REPL loop: `terminal.readMultilineInput` → slash command check → `conversation.runTurn`
- Non-interactive mode: piped stdin (`echo "question" | zerocode`) and `--print` flag for single-shot usage. Detects `!isatty(stdin)` and reads full input before sending
- Signal handling: SIGINT sets atomic `interrupted` flag. Streaming reader checks this flag between chunks and aborts the HTTP connection cleanly. Turn allocator `.free_all` runs even on interrupted turns to prevent leaks
- Three-tier allocator setup at startup

## External Dependencies

**C-linked**:
- Tree-sitter + language parser grammars (syntax highlighting)

**Zero external dependency (std only)**:
- HTTP/TLS: `std.http.Client`, `std.http.Server` (OAuth callback), `std.crypto.tls`
- JSON: `std.json`
- File I/O: `std.fs`
- Process management: `std.process.Child`
- Terminal: `std.posix.termios` + ANSI escapes

**Runtime (subprocess, optional)**:
- `rg` or `grep` for regex search fallback
- `git` for worktree operations

## Binary Size

Estimated 2-5MB ReleaseSafe (with Tree-sitter). Compared to Node.js Claude Code's hundreds of MB in node_modules.

## Compatibility

- Reads `CLAUDE.md` in addition to `ZEROCODE.md`
- Settings format compatible with claw-code's `settings.json` structure
- Hook format compatible with claw-code's hooks configuration
- Session JSON format follows claw-code conventions for potential migration
