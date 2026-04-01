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
| HTTP/TLS | std.http.Client | Zero external dependency |
| Terminal | std.posix.termios + ANSI | Zero external dependency |
| Reference impl | claw-code Rust source | Follow its patterns when design decisions are ambiguous |

## Memory Architecture

The core design advantage over Node.js. Three-tier arena allocator strategy:

```
Persistent Allocator (smp_allocator)
  - Process lifetime: CLI config, history file paths, signal state
  - Tiny footprint, never reset

  └── Session Allocator (ArenaAllocator)
        - Lifetime: one session (reset on /clear, session switch)
        - Holds: conversation history, plugin registry, MCP client state,
                 session config, permission rules
        
        └── Turn Allocator (ArenaAllocator)
              - Lifetime: one user message → response complete
              - Holds: API response parsing, tool execution intermediates,
                       JSON serialization, SSE frame buffers
              - Reset on turn completion → RSS drops immediately
              - This is where Node.js leaks — we reclaim deterministically
```

Why this fixes the RSS bloat:
- Node.js V8 GC is conservative; old-gen objects survive major GC cycles and RSS never returns to baseline
- Zig ArenaAllocator.reset() with retain_capacity keeps the virtual mapping but marks pages MADV_DONTNEED, allowing the kernel to reclaim physical memory immediately
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
- `Provider` interface (function pointer table) for future multi-provider support
- Only Anthropic implementation initially; OpenAI-compat addable as another Provider

**streaming.zig**:
- SSE frame parser: `event:`, `data:`, empty line delimiter
- Events: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`
- All parse output allocated on turn allocator → freed on turn reset

**auth.zig**:
- Priority: `ANTHROPIC_API_KEY` env var → OAuth PKCE
- OAuth flow: `/oauth/authorize` → local HTTP callback server → `/oauth/token`
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
- Same JSON merge strategy as claw-code
- Discovers both `CLAUDE.md` and `ZEROCODE.md`

Reference: claw-code `runtime/src/config.rs` (~40KB)

**session.zig**:
- Storage: `~/.zerocode/sessions/{session_id}.json`
- `--continue` resumes latest, `--resume {id}` resumes specific
- Lightweight index file for session listing (avoids scanning all JSON files)

**permissions.zig**:
- Three levels: `ReadOnly` < `WorkspaceWrite` < `DangerFullAccess`
- Per-tool allow/deny rules with glob support (`Bash(git:*)`)
- Prompter callback for user Y/N confirmation when permission insufficient

**compact.zig**:
- Triggers when context token count exceeds threshold
- Preserves recent N messages verbatim, summarizes older ones
- Builds new history on session allocator, old data freed

**sandbox.zig**:
- Linux namespaces (`clone` + `CLONE_NEWNS|NEWPID|NEWNET`)
- cwd restriction, network isolation per namespace

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
- Glob: `std.fs.Dir` walk-based, glob pattern matching
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
- Process lifecycle: startup, health check, restart, graceful shutdown
- Concurrent management of multiple MCP servers

Reference: claw-code `runtime/src/mcp_stdio.rs` (~62KB)

**sse.zig**:
- `std.http.Client` SSE endpoint connection
- Server→client: SSE stream; client→server: HTTP POST

**http.zig**:
- Streamable HTTP (latest MCP spec)
- Single endpoint request/response with session ID

**websocket.zig**:
- `std.http.Client` WebSocket upgrade
- Bidirectional JSON-RPC

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
- Each language parser is an independent shared object, link only what's needed

**terminal.zig**:
- Based on existing LCC `terminal.zig`, extended
- Raw mode, alternate screen, cursor control via `std.posix.termios` + ANSI escapes
- Readline-style line editing, history, multiline input
- Spinner animation during tool execution

### main.zig — Entry Point

- Argument parsing: manual (no external dep), same approach as LCC
- REPL loop: `terminal.readMultilineInput` → slash command check → `conversation.runTurn`
- Signal handling: SIGINT (Ctrl+C) interrupts current turn
- Three-tier allocator setup at startup

## External Dependencies

**C-linked**:
- Tree-sitter + language parser grammars (syntax highlighting)

**Zero external dependency (std only)**:
- HTTP/TLS: `std.http.Client`, `std.crypto.tls`
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
