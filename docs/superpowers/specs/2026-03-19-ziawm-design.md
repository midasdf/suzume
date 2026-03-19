# ziawm — Zig i3 Alternative Window Manager

## Overview

ziawm is an i3-compatible tiling window manager written in Zig. It provides i3-compatible IPC, config syntax, and i3bar protocol while being lighter and faster than i3 through direct xcb usage, zero GLib/pango/cairo dependency, and Zig's comptime optimizations. Primary target is HackberryPi Zero (720x720, aarch64) but works on any X11 Linux system.

**Core design:** i3-compatible externally, optimized Zig internals. Approach B — same API surface, better implementation.

## Target Environment

| Property | Value |
|----------|-------|
| Primary device | HackberryPi Zero (RPi Zero 2W) |
| Display | 720x720 HyperPixel4 (fbdev) |
| RAM | 512MB |
| CPU | Cortex-A53 (aarch64), overclocked 1.2GHz |
| Display server | X.org with xf86-video-fbdev |
| Secondary target | Any Linux x86_64/aarch64 with X11 |
| Wayland | Not supported (fbdev, no DRM/KMS) |

## Architecture

### File Structure

```
ziawm/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig          # Entry point, signal handling
│   ├── tree.zig          # Container tree structure (split, workspace, output)
│   ├── layout.zig        # Tree → screen coordinates (pure functions)
│   ├── xcb.zig           # xcb @cImport + helpers
│   ├── render.zig        # xcb drawing commands (borders etc)
│   ├── event.zig         # X11 event dispatch
│   ├── ipc.zig           # i3-compatible IPC (UNIX socket, JSON protocol)
│   ├── config.zig        # i3-compatible config parser + runtime reload
│   ├── command.zig       # i3 command execution engine (split h, move left, etc)
│   ├── criteria.zig      # [class="X" title="Y"] matching
│   ├── bar.zig           # i3bar protocol management
│   ├── workspace.zig     # Workspace management
│   ├── scratchpad.zig    # Scratchpad feature
│   ├── output.zig        # XRandR monitor management
│   └── atoms.zig         # EWMH/ICCCM atom management
├── ziawm-msg/
│   └── main.zig          # i3-msg compatible CLI tool
├── ziawm-bar/
│   └── main.zig          # i3bar compatible bar process
├── config/
│   └── default_config    # Default config file
└── tests/
    ├── test_tree.zig
    ├── test_layout.zig
    ├── test_config.zig
    ├── test_command.zig
    └── test_criteria.zig
```

3 binaries: `ziawm` (WM), `ziawm-msg` (IPC CLI), `ziawm-bar` (bar).

**Shared code:** `ipc.zig` contains both server (ziawm) and client (ziawm-msg, ziawm-bar) IPC protocol handling. The binary framing (magic + length + type + payload) encode/decode is shared. ziawm-msg and ziawm-bar import `ipc.zig` as a module from the main `src/`.

### Dependencies

**System libraries (linked via @cImport):**
- `xcb` — core X11 protocol
- `xcb-keysyms` — key symbol resolution
- `xcb-randr` — multi-monitor detection and hotplug
- `xcb-xkb` — keyboard handling
- `xkbcommon`, `xkbcommon-x11` — keymap processing
- `xft`, `fontconfig` — bar font rendering (ziawm-bar only)

**No external Zig packages.** No GLib, no pango, no cairo.

EWMH/ICCCM atoms are managed manually via raw `xcb_intern_atom` calls at startup. No `xcb-util-wm`, `xcb-icccm`, or `xcb-ewmh` dependencies — keeps the dependency count minimal and avoids pulling in unused helpers.

## Data Model — Container Tree

i3's core is a tree of containers. ziawm follows the same model.

```
Root
├── Output (HDMI-1)         ← physical monitor
│   ├── Workspace "1"
│   │   └── HSplit
│   │       ├── Window (Firefox)
│   │       └── VSplit
│   │           ├── Window (terminal)
│   │           └── Window (terminal)
│   └── Workspace "2"
│       └── Window (editor)
└── Output (DP-1)
    └── Workspace "3"
        └── Tabbed
            ├── Window (Slack)
            └── Window (Discord)
```

```zig
const Container = struct {
    type: enum { root, output, workspace, split, window },
    layout: enum { hsplit, vsplit, tabbed, stacked },

    // Tree structure (intrusive doubly-linked + parent)
    parent: ?*Container,
    children: ChildList,  // doubly-linked list

    // Coordinates (layout engine writes these)
    rect: Rect,           // allocated area
    window_rect: Rect,    // area minus borders

    // Window-specific (type == .window)
    window: ?WindowData,

    // Workspace-specific
    workspace: ?WorkspaceData,

    // Split-specific — percentage of parent's space this container occupies
    // In a 3-way split, children might have percentages [0.33, 0.33, 0.34]
    // `resize grow/shrink width 10 px` adjusts this container's percent and
    // redistributes the difference to the adjacent sibling
    percent: f32,         // 0.0-1.0, default: 1.0/num_siblings

    // State
    is_floating: bool,
    is_fullscreen: enum { none, window, global },
    is_focused: bool,
    marks: MarkList,      // user-defined marks
    dirty: bool,          // needs re-layout

    // Scratchpad
    is_scratchpad: bool,
};

const WindowData = struct {
    id: xcb.Window,
    class: []const u8,
    instance: []const u8,
    title: []const u8,
    transient_for: ?xcb.Window,
    urgency: bool,
};

const WorkspaceData = struct {
    name: []const u8,
    num: ?i32,            // workspace "1" → num=1, "chat" → num=null
    output: []const u8,   // assigned output name
};
```

**Differences from i3:**
- i3 uses `TAILQ` macros → ziawm uses Zig intrusive linked list
- i3's `Con` struct is monolithic → ziawm uses optional fields to reduce memory per node
- Focus stack is managed by child ordering (last-focused child at head), same as i3

**Layout calculation flow:**
```
config reload / window add / command exec
  → tree structure change, mark dirty
    → layout.render_tree(root) recalculates dirty subtrees only
      → render.apply(tree) sends xcb operations for dirty containers only
```

## Layout Engine

Pure functions in `layout.zig`, zero xcb dependency.

**Supported layouts:**
- `hsplit` — horizontal split (windows side by side)
- `vsplit` — vertical split (windows stacked vertically)
- `tabbed` — tabbed view (one visible, tabs at top)
- `stacked` — stacked view (one visible, titles stacked)

**Dirty flag optimization:**
Only recalculate subtrees where `dirty == true`. Single window move doesn't trigger full tree recalculation.

**Strut-aware area calculation:**
When a window sets `_NET_WM_STRUT_PARTIAL` (bars, panels), the layout engine subtracts the reserved area from the output's usable region before tiling. The usable area per output is recalculated whenever struts change.

## IPC Protocol (i3-compatible)

```
UNIX socket: /run/user/{uid}/ziawm/ipc.sock
```

**Binary protocol (identical to i3):**
```
"i3-ipc" (6 bytes magic) + payload length (u32 LE) + message type (u32 LE) + JSON payload
```

Uses `"i3-ipc"` magic string so `i3-msg`, `i3blocks`, `i3status` etc. connect directly.

**Supported message types:**

| Type | Name | Description |
|------|------|-------------|
| 0 | RUN_COMMAND | Execute command (split h, move left, etc) |
| 1 | GET_WORKSPACES | List workspaces |
| 2 | SUBSCRIBE | Subscribe to events |
| 3 | GET_OUTPUTS | List monitors |
| 4 | GET_TREE | Full tree JSON dump |
| 5 | GET_MARKS | List marks |
| 6 | GET_BAR_CONFIG | Bar configuration |
| 7 | GET_VERSION | Version info |
| 8 | SEND_TICK | Not supported (reserved for i3 compatibility) |
| 9 | GET_CONFIG | Current config |
| 10 | GET_BINDING_MODES | Binding modes |

**Supported events (via SUBSCRIBE):**

| Event | Description |
|-------|-------------|
| workspace | Workspace change |
| output | Monitor connect/disconnect |
| mode | Binding mode change |
| window | Window focus/close/move etc |
| barconfig_update | Bar config change |
| binding | Keybind triggered |

**JSON handling:**
- i3 uses yajl (C library) → ziawm uses `std.json`
- GET_TREE response buffer reused across calls to minimize allocation
- IPC handled in same event loop thread via epoll (no separate thread)

**Socket discovery (i3-compatible):**
- Set `I3SOCK` environment variable to socket path on startup (inherited by child processes)
- Set `_I3_SOCKET_PATH` property on X root window
- `ziawm-msg` checks: `I3SOCK` env → root window atom → default path
- This allows `i3-msg` to find the socket without `-s` flag

**ziawm-msg:**
```bash
ziawm-msg 'split h'
ziawm-msg -t get_workspaces
ziawm-msg -t get_tree

# i3-msg also works (same protocol)
i3-msg -s /run/user/1000/ziawm/ipc.sock 'focus left'
```

## Config Syntax

i3-compatible config syntax. File location: `~/.config/ziawm/config`

**Supported constructs:**

```bash
# Variables
set $mod Mod4
set $term st

# Keybinds
bindsym $mod+Return exec $term
bindsym $mod+Shift+q kill
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Shift+h move left
bindsym $mod+v split v
bindsym $mod+s layout stacking
bindsym $mod+w layout tabbed
bindsym $mod+e layout toggle split
bindsym $mod+f fullscreen toggle
bindsym $mod+Shift+space floating toggle
bindsym $mod+space focus mode_toggle
bindsym $mod+a focus parent
bindsym $mod+minus scratchpad show
bindsym $mod+Shift+minus move scratchpad

# Workspaces
bindsym $mod+1 workspace number 1
bindsym $mod+Shift+1 move container to workspace number 1

# Monitor focus
bindsym $mod+comma focus output left
bindsym $mod+period focus output right

# Resize mode
mode "resize" {
    bindsym h resize shrink width 10 px
    bindsym l resize grow width 10 px
    bindsym j resize grow height 10 px
    bindsym k resize shrink height 10 px
    bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# Appearance
default_border pixel 1
gaps inner 0
gaps outer 0

# Colors
client.focused          #4c7899 #285577 #ffffff #2e9ef4   #285577
client.unfocused        #333333 #222222 #888888 #292d2e   #222222

# Criteria
for_window [class="mpv"] floating enable
for_window [window_role="dialog"] floating enable

# Workspace assignment
assign [class="Firefox"] workspace 2

# Exec
exec_always --no-startup-id xrdb -merge ~/.Xresources
exec --no-startup-id dunst

# Bar
bar {
    status_command i3blocks
    position top
    colors {
        background #222222
        statusline #dddddd
    }
}
```

**Parser design:**
- Line-based, single-pass
- `set $var value` → variable table, expanded in subsequent lines
- `mode "name" { ... }` → one level of nesting only (same as i3)
- `#` for comments
- Unknown config lines → warning and skip (no crash)

**Reload:**
- `bindsym $mod+Shift+c reload` → re-parse config, re-grab keys, notify bar
- On any parse error: keep old config, log + notify error

**Config file search order:**
1. `$XDG_CONFIG_HOME/ziawm/config` (typically `~/.config/ziawm/config`)
2. `~/.ziawm/config`
3. `/etc/ziawm/config`

**Not supported in v1:**
- `bindcode` (keysym only, keycode later)
- `no_focus`
- `popup_during_fullscreen`

## i3bar Protocol + ziawm-bar

**ziawm-bar role:**
- ziawm spawns ziawm-bar based on `bar {}` config block
- ziawm-bar spawns `status_command` (i3blocks etc) as child process
- Receives workspace info via IPC, renders to its own X window
- Gets output geometry from IPC (GET_OUTPUTS), does not query RandR directly

**Protocol (i3bar protocol compliant):**

status_command → ziawm-bar (stdin):
```json
{"version":1,"click_events":true}
[
[{"full_text":"CPU 23%","color":"#ffffff"},{"full_text":"MEM 45%"}],
```

ziawm-bar → status_command (stdout, click events):
```json
{"name":"cpu","button":1,"x":120,"y":5}
```

**Rendering vs i3bar:**

| i3bar | ziawm-bar |
|-------|-----------|
| pango + cairo | Xft font rendering + xcb rectangles |
| depends: pango, cairo, glib | depends: libxft, fontconfig |
| ~15MB RSS | target: <3MB RSS |

**Bar layout:**
```
┌─[1][2][3]──────────────[CPU 23%][MEM 45%][12:34]─┐
```
- Left: workspace buttons (clickable)
- Right: status_command output
- Colors from config

**Communication:**
```
ziawm ←IPC socket→ ziawm-bar ←stdin/stdout→ i3blocks
```

## Command Execution + Child Process Spawning

**`exec` command:**
- `exec` and `exec_always` in config, `exec` command via IPC/keybind
- All commands pass through `/bin/sh -c "command"` (same as i3) to support shell features (pipes, env vars, `&`)
- `--no-startup-id` flag suppresses startup notification (sets `_NET_STARTUP_ID`)

**Spawn mechanism:**
1. `fork()` in the WM process
2. Child: `setsid()` to detach from WM's process group
3. Child: close xcb fd and IPC fds (prevent inheritance)
4. Child: set `DISPLAY`, `I3SOCK` environment variables
5. Child: `execvp("/bin/sh", ["/bin/sh", "-c", command])`
6. Parent: continues event loop (SIGCHLD handled via signalfd to reap)

**`exec` vs `exec_always`:**
- `exec` — runs only on initial startup, not on config reload
- `exec_always` — runs on every config reload

**Window kill protocol:**
1. `kill` command: check if window supports `WM_DELETE_WINDOW` in `WM_PROTOCOLS`. If yes, send `ClientMessage` with `WM_DELETE_WINDOW` atom (graceful close). If no, `xcb_kill_client` immediately.
2. `kill kill` command: always `xcb_kill_client` (force kill, bypasses graceful close).
3. No timeout — same behavior as i3.

**`assign` directive processing:**
- `assign [criteria] workspace N` rules stored at config parse time
- On `MapRequest` (new window managed), run all assign rules against the window
- If matched, move the window to the target workspace before tiling
- Processed before `for_window` rules

## Focus Model

**Default: click-to-focus** (same as i3 default).

Config directives:
```bash
focus_follows_mouse yes|no    # default: yes (i3 default)
focus_wrapping yes|no         # default: yes
```

**Focus behavior:**
- `focus_follows_mouse yes` — EnterNotify events change focus (sloppy focus)
- `focus_follows_mouse no` — only explicit focus commands or clicks change focus
- Click on window → focus (always, regardless of focus_follows_mouse)
- Focus within fullscreen: only the fullscreen container and its children receive focus

**Focus stack:**
- Managed by child ordering in the tree (last-focused child moved to head of siblings)
- `focus parent` / `focus child` navigate up/down the tree
- `focus mode_toggle` switches between tiling and floating layer

## Criteria Matching

```bash
# Syntax
[class="Firefox" instance="Navigator" title="GitHub*"]
```

**Supported properties (v1):**

| Property | Match target | Method |
|----------|-------------|--------|
| `class` | WM_CLASS class | exact or glob (`*` only) |
| `instance` | WM_CLASS instance | same |
| `title` | _NET_WM_NAME / WM_NAME | same |
| `window_role` | WM_WINDOW_ROLE | same |
| `con_mark` | user-defined mark | same |
| `floating` | floating state | bool |
| `workspace` | workspace name/number | exact |

Glob (`*` wildcard) instead of i3's PCRE regex. Avoids libpcre dependency while covering practical use cases.

## Marks

```bash
bindsym $mod+m mark myterm
bindsym $mod+g [con_mark="myterm"] focus
unmark myterm
```

- Multiple marks per container
- Arbitrary string names
- Available via GET_MARKS IPC

## Scratchpad

```bash
bindsym $mod+Shift+minus move scratchpad
bindsym $mod+minus scratchpad show
```

- Hidden workspace `__i3_scratch` holds scratchpad containers
- `scratchpad show` displays as floating on current workspace
- Multiple windows in scratchpad cycle on repeated `scratchpad show`

## Event Loop

**Single-threaded, epoll-based:**

```
         ┌─────────────┐
         │   epoll fd   │
         ├─────────────┤
         │ xcb fd       │← X11 events
         │ ipc listen fd│← new IPC connections
         │ ipc client fd│← existing IPC clients (multiple)
         │ signal fd    │← signalfd(SIGCHLD,SIGTERM,SIGHUP)
         └──────┬──────┘
                │
                ▼
         event_loop() {
           epoll_wait()
           → xcb: handle_x11_event()
           → ipc: handle_ipc_message()
           → signal: handle_signal()
         }
```

**Performance advantages over i3:**

| Area | i3 | ziawm |
|------|-----|-------|
| Event dispatch | Function pointer table | comptime-generated switch (branch prediction friendly) |
| Tree traversal | TAILQ + pointer chasing | Same but cache-line-aware struct layout |
| Layout calc | Recursive, all nodes | Dirty flag, changed subtrees only |
| IPC JSON gen | yajl (stream API) | std.json.writeStream + fixed buffer reuse |
| Config parse | Hand-written flex/bison style | Line-based single-pass, minimal allocation |
| String compare | strcmp scattered | comptime interned strings where possible |

**Signals:**
- `SIGCHLD` → signalfd reap (prevent zombies)
- `SIGTERM/SIGINT` → clean shutdown
- `SIGHUP` → restart (see below)
- `SIGUSR1` → config reload only

**Restart vs Reload:**
- **Reload** (`reload` command, `SIGUSR1`): re-parse config, re-grab keys, notify bar. Tree preserved. `exec_always` re-runs, `exec` does not.
- **Restart** (`restart` command, `SIGHUP`): serialize current tree to `/run/user/{uid}/ziawm/restart-state.json`, then `execvp` self. On startup, if restart state file exists, deserialize tree and restore window layout. `exec` commands are suppressed during restart (only run on fresh startup). `exec_always` runs on both startup and restart. This preserves window positions across restarts, same as i3.

**Platform note:** signalfd and epoll are Linux-specific. ziawm targets Linux only (not BSDs).

## XRandR + Output Management

**Monitor detection:**
```
Startup: xcb_randr_get_screen_resources → create Output per CRTC
Runtime: RandR ScreenChangeNotify → re-detect, apply diff
```

**Output ↔ Workspace assignment:**
```bash
workspace 1 output HDMI-1
workspace 2 output HDMI-1
workspace 3 output DP-1
```
Unassigned workspaces created on currently focused output.

**Monitor events:**

| Event | Action |
|-------|--------|
| New output connected | Create empty workspace, move per config assignment |
| Output disconnected | Move all workspaces to remaining output |
| Resolution change | Re-layout all workspaces on that output |

## EWMH/ICCCM Support

**EWMH atoms:**

| Atom | Purpose |
|------|---------|
| `_NET_SUPPORTED` | Advertise supported atoms |
| `_NET_SUPPORTING_WM_CHECK` | WM existence check |
| `_NET_WM_NAME` | Window title |
| `_NET_WM_STATE` | fullscreen, demands_attention |
| `_NET_WM_STATE_FULLSCREEN` | Fullscreen toggle |
| `_NET_WM_STATE_DEMANDS_ATTENTION` | Urgency hint |
| `_NET_WM_WINDOW_TYPE` | dialog, splash detection |
| `_NET_ACTIVE_WINDOW` | Focused window |
| `_NET_CURRENT_DESKTOP` | Current workspace |
| `_NET_NUMBER_OF_DESKTOPS` | Workspace count |
| `_NET_DESKTOP_NAMES` | Workspace names |
| `_NET_WM_DESKTOP` | Window's workspace |
| `_NET_WM_STRUT_PARTIAL` | Bar screen reservation |
| `_NET_CLIENT_LIST` | Managed window list |
| `_NET_WM_PID` | Process ID |

**ICCCM atoms:**

| Atom | Purpose |
|------|---------|
| `WM_PROTOCOLS` | Protocol negotiation |
| `WM_DELETE_WINDOW` | Graceful close |
| `WM_TAKE_FOCUS` | Focus handling |
| `WM_CLASS` | class/instance (for criteria) |
| `WM_NAME` | Title (_NET_WM_NAME fallback) |
| `WM_NORMAL_HINTS` | Size hints |
| `WM_HINTS` | Urgency etc |
| `WM_TRANSIENT_FOR` | Dialog parent-child |
| `WM_WINDOW_ROLE` | For criteria matching |

## Floating (Minimal, v1)

**Auto-float only:**
- `WM_TRANSIENT_FOR` set (dialogs)
- `_NET_WM_WINDOW_TYPE_DIALOG`, `_SPLASH`, `_NOTIFICATION`
- `WM_NORMAL_HINTS` min_size == max_size (fixed size)
- `for_window [criteria] floating enable` match

`floating toggle` command works, but mouse move/resize of floating windows deferred. Keyboard `resize` command supported.

## Memory Management

- Container pool via arena allocator — initial pool: 64 containers, doubles on exhaustion, never shrinks. Freed containers returned to pool, reused on next window open
- IPC JSON buffer: single fixed-size buffer, reused across calls
- No dynamic config string allocation beyond initial parse
- Target RSS: < 2MB (i3 typically 5-10MB)

## Testing Strategy

| Layer | Method | xcb dependency |
|-------|--------|----------------|
| tree.zig | Unit tests (node operations, move, reparent) | None |
| layout.zig | Unit tests (coordinate calculation accuracy) | None |
| config.zig | Unit tests (parse result verification) | None |
| command.zig | Unit tests (tree manipulation commands) | None |
| criteria.zig | Unit tests (matching logic) | None |
| ipc.zig | Unit tests (protocol encode/decode) | None |
| Integration | Run on Xephyr | Yes |

```bash
# Unit tests
zig build test

# Integration tests (Xephyr, 720x720 to match HackberryPi)
Xephyr -br -ac -noreset -screen 720x720 :1 &
DISPLAY=:1 zig-out/bin/ziawm
```

## Build

```zig
// build.zig — 3 binaries
const ziawm = b.addExecutable(.{ .name = "ziawm", ... });
ziawm.linkSystemLibrary("xcb");
ziawm.linkSystemLibrary("xcb-keysyms");
ziawm.linkSystemLibrary("xcb-randr");
ziawm.linkSystemLibrary("xcb-xkb");
ziawm.linkSystemLibrary("xkbcommon");
ziawm.linkSystemLibrary("xkbcommon-x11");
ziawm.linkLibC();

const ziawm_msg = b.addExecutable(.{ .name = "ziawm-msg", ... });
ziawm_msg.linkSystemLibrary("xcb");  // for root window atom lookup (socket discovery)
ziawm_msg.linkLibC();

const ziawm_bar = b.addExecutable(.{ .name = "ziawm-bar", ... });
ziawm_bar.linkSystemLibrary("xcb");
ziawm_bar.linkSystemLibrary("xft");
ziawm_bar.linkSystemLibrary("fontconfig");
ziawm_bar.linkLibC();
```

**Cross-compilation for HackberryPi:**
```bash
zig build -Dtarget=aarch64-linux-gnu --sysroot /path/to/hackberry-sysroot
```

**Binary size targets (ReleaseSmall):**

| Binary | Target |
|--------|--------|
| ziawm | < 200KB |
| ziawm-msg | < 30KB |
| ziawm-bar | < 100KB |

## Non-Goals (v1)

- **Wayland support** — HackberryPi has no DRM/KMS
- **Mouse move/resize for floating** — keyboard resize only
- **PCRE regex in criteria** — glob matching sufficient
- **bindcode** — keysym only
- **Window decorations / title bars** — borders only
- **Animations** — unnecessary on constrained hardware
- **Session management** — not needed
