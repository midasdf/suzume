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
- **JavaScript engine** — QuickJS-ng with full DOM/Web API (see Benchmark below)
- X11/XCB framebuffer rendering via libnsfb
- FreeType + HarfBuzz text shaping (CJK support)
- Tab browsing, keyboard navigation, find-in-page
- Window resize with re-layout and media query re-evaluation
- Mouse wheel scrolling
- SSL certificate fallback with hostname verification

## Benchmark

**111/111 (100%)** on the internal capability test suite.

| Category | Score | Details |
|----------|-------|---------|
| DOM Core | 28/28 | createElement, querySelector, classList, innerHTML, etc. |
| CSS / Style | 5/5 | getComputedStyle, style manipulation |
| Events | 6/6 | addEventListener, removeEventListener, bubbling, dispatchEvent |
| Timers | 6/6 | setTimeout, setInterval, requestAnimationFrame, performance.now |
| Web APIs | 6/6 | console, JSON, window, navigator |
| ES6+ | 21/21 | let/const, arrow functions, async/await, Proxy, optional chaining, etc. |
| Form Elements | 4/4 | input.value, textarea.value, select.value |
| Mouse Events | 3/3 | mousedown, mouseup, mousemove |
| Event Correctness | 1/1 | removeEventListener identity check |
| Scroll APIs | 5/5 | scrollTo, scrollBy, scrollX/Y, pageYOffset |
| Navigation APIs | 5/5 | location.assign/replace, history.pushState/replaceState/back |
| XHR | 5/5 | XMLHttpRequest with open/send/setRequestHeader/readyState |
| MutationObserver | 3/3 | constructor, observe, disconnect |
| Advanced Web | 12/12 | fetch, localStorage, Canvas 2D, WebSocket, Worker, Blob, crypto, etc. |
| Error Handling | 2/2 | try/catch, TypeError |

Additional test suites:
- **QuickJS ES features**: 61/63 (97%) — ES2024 coverage
- **DOM API audit**: 74/74 (100%) — TextEncoder, Intl, AbortController, etc.
- **Real site JS errors**: 0 on HN, Reddit, CNN, Wikipedia, DDG, Lobsters, npm

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
