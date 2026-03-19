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
- Table layout with colspan, cellpadding, content-based column sizing
- ::before/::after pseudo-elements
- :link pseudo-class, CSS background propagation (spec-compliant)
- CSS transforms (translate)
- 120+ CSS properties, 200+ unit tests
- HTML5 parsing via lexbor
- JavaScript via QuickJS-ng (basic DOM API, event handling)
- X11/XCB framebuffer rendering via libnsfb
- FreeType + HarfBuzz text shaping (CJK support)
- Tab browsing, keyboard navigation, find-in-page
- Window resize with re-layout and media query re-evaluation
- Mouse wheel scrolling
- SSL certificate fallback with hostname verification

## Tested Sites

| Site | Status | Notes |
|------|--------|-------|
| Hacker News | Works well | Correct colors, layout density, text spacing |
| GitHub | Works well | File lists, README rendering |
| Brave Search | Works well | Search results with sublinks |
| MDN | Works well | Article content fully readable |
| old.reddit.com | Works well | 2-column layout, sidebar, posts |
| CSS Zen Garden | Works well | Background colors, text layout |
| Smashing Magazine | Works well | Articles, categories, search bar |
| Wikipedia | Readable | Article content, limited JS |
| example.com | Near-perfect | Background propagation, centering |
| anthropic.com | Partially working | Heavy JS, basic content visible |

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
├── net/          # HTTP loader (libcurl, SSL fallback)
├── ui/           # Browser chrome (tabs, address bar, input)
└── features/     # Adblock, config, storage, userscript
```

## CSS Engine

The CSS engine is fully self-implemented in Zig with no external CSS library dependency:

- **Tokenizer** — CSS Syntax Level 3 compliant, zero-copy streaming
- **Parser** — Recursive descent producing stylesheet AST with shorthand expansion
- **Selectors** — Right-to-left matching with rule index and bloom filter optimization
- **Cascade** — Full cascade ordering (UA/author/inline), specificity, style sharing cache
- **Properties** — 120+ properties with color, length, percentage, calc() parsing
- **Variables** — CSS custom properties with var() resolution and cycle detection
- **Media queries** — @media with width, height, prefers-color-scheme

## License

MIT
