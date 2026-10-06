# Renderer microbenchmarks

## 2026-10-06: remove unsafe style sharing

Apple A18 Pro, macOS 27.0.1, Zig 0.16.0, stripped ReleaseSafe application,
five fresh processes per binary. The baseline uses `544d638`'s cascade with the
same benchmark harness; the fixed build removes the style-sharing cache.
Dependency dylibs and workloads are unchanged. Local binary paths are redacted
in the stored [before](css-cache-before.json) and [after](css-cache-after.json) reports.

| Workload | Elements | Median before | Median after | p95 before | p95 after |
|---|---:|---:|---:|---:|---:|
| 10,000 sibling cells | 10,003 | 313.83 ms | 13.52 ms | 322.15 ms | 13.89 ms |
| 1,000 rows of three cells | 4,003 | 4.04 ms | 4.64 ms | 4.22 ms | 4.99 ms |

Median peak RSS for the whole headless process executing both workloads:
**91.59 MiB → 48.59 MiB** (approximately 47% lower).

The sibling case is approximately **23.2× faster** because it no longer counts
all preceding siblings for every element. The repeated-row case is approximately
**15% slower**: its old cache hit often, but that cache was not safe for general
CSS. It could reuse colors across different ancestor/attribute selectors, omit
font-family inheritance, and skip creation of scoped custom-property maps.
Five production regressions now check those contexts and retained variable-map
lifetime. A future sharing cache
must validate matching and the complete inherited/variable context.

These are **not browser startup, page-load, GUI RSS, idle CPU or competitor
benchmarks**. Timing includes CSS parsing, indexing and cascade, but excludes DOM
parsing. Peak RSS includes DOM creation and all loaded libraries across both
cases, not just stylesheet memory. There is no layout, painting, network or page
JavaScript. Five samples are an initial local baseline, not a universal ranking.

## Reproduce

Build ReleaseSafe first (`bash scripts/build-macos.sh -j4` on macOS or
`zig build -Doptimize=ReleaseSafe` on Linux), then:

```sh
python3 tests/cascade_benchmark.py --repeat 5
# Or compare a saved, relocatable application binary:
python3 tests/cascade_benchmark.py /path/to/Suzume.app/Contents/MacOS/suzume --repeat 5
```

The benchmark asserts element counts and every cell's computed color. The
collector uses `/usr/bin/time` for peak process RSS, records each sample, and
reports median and nearest-rank p95. New binaries report their optimization
mode. CI runs a one-sample correctness/collector smoke test without a timing
threshold; runner hardware and load vary.

## 2026-10-06: bounded text measurement reuse

Same Apple A18 Pro/macOS/Zig/ReleaseSafe environment. Five process runs,
20,000 measurements per case. [Raw samples](text-measure.jsonl).

| Workload | Median transient/uncached | Median optimized |
|---|---:|---:|
| Three repeated text samples | 289.99 ms | 146.77 ms |
| 20,000 unique row labels | 67.12 ms | 65.90 ms |

Repeated measurements are about **1.98× faster**; unique inputs improve about
**1.8%** in this sample. The comparison disables both new optimizations and
reproduces the old per-measure HarfBuzz buffer lifecycle within the same binary.
It is not a historical-binary or whole-browser comparison. Font/glyph data is
warmed identically, every measured width is checked against uncached shaping,
and each mode produces the same checksum. Unique label formatting is included
in both timings; repeated input favors memoization and is not a general-page
speedup. Baseline runs first in each pair, so order/system noise remain limitations.

Optimized renderers retain at most 16 exact-byte metric entries for strings of
128 bytes or fewer (2,560 bytes per font renderer), invalidated on fallback
replacement. Larger text is not cached; measurement scratch buffers are retained
only for inputs up to 4,096 bytes. Drawing still shapes/rasterizes normally.
Resize re-layout also reuses existing line-list storage instead of abandoning
it on every pass; a 100-pass regression checks stable storage and geometry.
This does **not** resolve the existing whole-page/runtime retention on navigation.

```sh
zig-out/Suzume.app/Contents/MacOS/suzume --bench-text # macOS
zig-out/bin/suzume --bench-text # Linux
```

CI runs both text workloads with width checks, without a performance threshold.
