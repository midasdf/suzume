# suzume

[![Zig](https://img.shields.io/badge/Zig-0.15+-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Linux](https://img.shields.io/badge/Platform-Linux-yellow?logo=linux&logoColor=white)](https://kernel.org)

Lightweight GUI web browser written in Zig. Targets Raspberry Pi Zero 2W (512MB RAM, Cortex-A53).

> **Note:** This project is under active development and not yet ready for general use.

## Features

- **Self-implemented CSS engine** — tokenizer, parser, selectors, cascade (no LibCSS dependency)
- CSS custom properties (var()), calc(), clamp(), min()/max()
- CSS Grid layout with track sizing, spans, auto-placement
- Flexbox layout with wrap support
- ::before/::after pseudo-elements
- CSS transforms (translate)
- 120+ CSS properties, 200+ unit tests
- HTML5 parsing via lexbor
- JavaScript via QuickJS-ng (basic DOM API)
- X11/XCB framebuffer rendering via libnsfb
- FreeType + HarfBuzz text shaping (CJK support)
- Tab browsing, keyboard navigation, search

## Tested Sites

| Site | Status |
|------|--------|
| GitHub | Works well |
| Brave Search | Works well |
| Hacker News | Works well |
| Wikipedia | Readable |
| MDN | Works well |
| old.reddit.com | Works well |
| CSS Zen Garden | Works well |
| anthropic.com | Partially working |

## Building

```bash
zig build              # native build
zig build run          # run browser
zig build test-css     # run CSS engine tests
```

### Cross-compile for RPi Zero 2W (aarch64)

```bash
zig build -Dtarget=aarch64-linux-gnu.2.38 -Doptimize=ReleaseFast --search-prefix ~/suzume-sysroot/usr
```

## Architecture

```
src/
├── css/          # Self-implemented CSS engine (tokenizer, parser, selectors, cascade)
├── dom/          # DOM tree (lexbor wrapper)
├── layout/       # Layout engine (block, flex, grid, table, inline)
├── paint/        # Framebuffer painter (libnsfb)
├── js/           # JavaScript runtime (QuickJS-ng)
├── net/          # HTTP loader (libcurl)
├── ui/           # Browser chrome (tabs, address bar, input)
└── features/     # Adblock, config, storage, userscript
```

## License

MIT
