# CSS cascade measurements

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
