# suzume WPT Results — 2026-03-25

## Combined Scores (testharness + reftest)

| Area | testharness | reftest | Combined |
|------|-------------|---------|----------|
| css-box | 299/307 (97.4%) | 67/67 (100%) | **97.9%** |
| css-flexbox | ~3/3 | 706/771 (91.6%) | **~91.5%** |
| css-text | ~870/1661 (52%) | 1093/1093 (100%) | **~71.3%** |
| css-display | 334/488 (68.4%) | 74/78 (94.9%) | **72.1%** |
| css-variables | 29/134 (21.6%) | 180/180 (100%) | **66.6%** |
| dom/nodes | ~1820/3982 (45.7%) | - | **45.7%** |
| css-values | ~950/3350 (28.4%) | 154/178 (86.5%) | **~31.3%** |
| css-color | 1673/5946 (28.1%) | 252/252 (100%) | **31.1%** |
| dom/events | ~54/365 (14.9%) | - | **14.9%** |

## Reftest Summary

**Total: ~2526/2619 = 96.4%**

| Area | Pass/Total |
|------|------------|
| css-variables | 180/180 (100%) |
| css-color | 252/252 (100%) |
| css-text | 1093/1093 (100%) |
| css-box | 67/67 (100%) |
| css-display | 74/78 (95%) |
| css-values | 154/178 (87%) |
| css-flexbox | 706/771 (92%) |

## Session Stats

- 38 commits pushed to main
- ~2500 testharness subtests improved
- ~2526 reftests passing (new capability)
- Key implementations: WebDriver, DOMException, CSS Color 4,
  multi-window, :is()/:where(), classList, reftest runner
