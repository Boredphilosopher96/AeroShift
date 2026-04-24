# Tree Storage Benchmark: Object Graph Baseline vs Object Graph Optimized

Captured on 2026-04-24 with:

- Before: `AEROSHIFT_TREE_BENCH_BACKEND_LABEL=object-graph-baseline swift test --filter TreeTopologyScaleBenchmarkTest`
- After: `AEROSHIFT_TREE_BENCH_BACKEND_LABEL=object-graph-optimized swift test --filter TreeTopologyScaleBenchmarkTest`

These numbers are diagnostic. They are single local debug-build runs, not stable pass/fail thresholds.

## Summary

The arena-backed tree experiment was abandoned. The current direction keeps the existing object graph as the topology source of truth and optimizes the hot object-graph paths:

- Per-parent sibling-index cache for `ownIndex`, move, swap, focus-direction checks, and invariant checks.
- Per-subtree leaf-window cache with ancestor invalidation on child insert/remove for repeated DFS focus/list paths.
- Adaptive child storage that stays dense for normal sibling counts and switches to chunked storage for wide sibling lists.

Compared with the old object graph baseline, this keeps the simple domain model and removes the broad arena overhead. In this run, 21 measurements are faster by at least 5%, 27 are effectively unchanged within 5%, and 10 are slower by at least 5%. The strongest improvements are `own-index`, repeated DFS focus, focus-direction lookup, and insert-at-end on wide lists. The remaining regressions are mostly small mutation/layout overheads from cache maintenance and compatibility materialization.

## Before/After Results

| Operation | Scale | Baseline seconds | Optimized seconds | Delta |
| --- | ---: | ---: | ---: | ---: |
| own-index | 1x64 | 0.000003934 | 0.000000000 | -100.0% |
| ordered-traversal | 1x64 | 0.000019073 | 0.000019073 | +0.0% |
| dfs-leaf-traversal | 1x64 | 0.000014067 | 0.000012994 | -7.6% |
| focus-dfs | 1x64 | 0.000015974 | 0.000001907 | -88.1% |
| focus-direction | 1x64 | 0.000013947 | 0.000007987 | -42.7% |
| layout-traversal | 1x64 | 0.000024080 | 0.000023007 | -4.5% |
| insert-beginning | 1x64 | 0.005254030 | 0.002416968 | -54.0% |
| insert-middle | 1x64 | 0.002190948 | 0.002261996 | +3.2% |
| insert-end | 1x64 | 0.000012994 | 0.000009894 | -23.9% |
| close-beginning | 1x64 | 0.002197981 | 0.002254009 | +2.5% |
| close-middle | 1x64 | 0.002115011 | 0.002243996 | +6.1% |
| close-end | 1x64 | 0.002082944 | 0.002170920 | +4.2% |
| swap-same-parent | 1x64 | 0.004352927 | 0.004526973 | +4.0% |
| own-index | 5x200 | 0.000008941 | 0.000000000 | -100.0% |
| ordered-traversal | 5x200 | 0.000043035 | 0.000049949 | +16.1% |
| dfs-leaf-traversal | 5x200 | 0.000038981 | 0.000025988 | -33.3% |
| focus-dfs | 5x200 | 0.000038981 | 0.000000954 | -97.6% |
| focus-direction | 5x200 | 0.000022054 | 0.000005007 | -77.3% |
| layout-traversal | 5x200 | 0.000036001 | 0.000038028 | +5.6% |
| insert-beginning | 5x200 | 0.002241969 | 0.002186060 | -2.5% |
| insert-middle | 5x200 | 0.002238989 | 0.002126098 | -5.0% |
| insert-end | 5x200 | 0.000043035 | 0.000015020 | -65.1% |
| close-beginning | 5x200 | 0.002271056 | 0.002164960 | -4.7% |
| close-middle | 5x200 | 0.002202034 | 0.002294064 | +4.2% |
| close-end | 5x200 | 0.002184033 | 0.002285957 | +4.7% |
| move-across-workspaces | 5x200 | 0.002251983 | 0.002279043 | +1.2% |
| swap-same-parent | 5x200 | 0.004326940 | 0.004492044 | +3.8% |
| swap-cross-parent | 5x200 | 0.004429936 | 0.004621029 | +4.3% |
| own-index | 20x250 | 0.000012040 | 0.000000000 | -100.0% |
| ordered-traversal | 20x250 | 0.000056028 | 0.000054955 | -1.9% |
| dfs-leaf-traversal | 20x250 | 0.000048041 | 0.000030994 | -35.5% |
| focus-dfs | 20x250 | 0.000048995 | 0.000001073 | -97.8% |
| focus-direction | 20x250 | 0.000027895 | 0.000005960 | -78.6% |
| layout-traversal | 20x250 | 0.000039935 | 0.000043988 | +10.1% |
| insert-beginning | 20x250 | 0.002175927 | 0.002351999 | +8.1% |
| insert-middle | 20x250 | 0.002146959 | 0.002268076 | +5.6% |
| insert-end | 20x250 | 0.000033975 | 0.000018954 | -44.2% |
| close-beginning | 20x250 | 0.002154946 | 0.002174020 | +0.9% |
| close-middle | 20x250 | 0.002196908 | 0.002161980 | -1.6% |
| close-end | 20x250 | 0.002166033 | 0.002117991 | -2.2% |
| move-across-workspaces | 20x250 | 0.002250075 | 0.002331972 | +3.6% |
| swap-same-parent | 20x250 | 0.004364014 | 0.004499078 | +3.1% |
| swap-cross-parent | 20x250 | 0.004577994 | 0.005149007 | +12.5% |
| own-index | 50x200 | 0.000010967 | 0.000002980 | -72.8% |
| ordered-traversal | 50x200 | 0.000048995 | 0.000051022 | +4.1% |
| dfs-leaf-traversal | 50x200 | 0.000043988 | 0.000078917 | +79.4% |
| focus-dfs | 50x200 | 0.000043988 | 0.000002027 | -95.4% |
| focus-direction | 50x200 | 0.000027061 | 0.000006914 | -74.4% |
| layout-traversal | 50x200 | 0.000038981 | 0.000042915 | +10.1% |
| insert-beginning | 50x200 | 0.002260923 | 0.002349019 | +3.9% |
| insert-middle | 50x200 | 0.002273917 | 0.002213001 | -2.7% |
| insert-end | 50x200 | 0.000030994 | 0.000018001 | -41.9% |
| close-beginning | 50x200 | 0.002192974 | 0.002299070 | +4.8% |
| close-middle | 50x200 | 0.002233982 | 0.002497911 | +11.8% |
| close-end | 50x200 | 0.002226949 | 0.002250910 | +1.1% |
| move-across-workspaces | 50x200 | 0.002349019 | 0.002367973 | +0.8% |
| swap-same-parent | 50x200 | 0.004319072 | 0.004372001 | +1.2% |
| swap-cross-parent | 50x200 | 0.004400969 | 0.004552007 | +3.4% |
