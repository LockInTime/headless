# P2 benchmark

This benchmark compares the code an agent needs to visit the fixture dashboard,
record through the `Continue` transition, and save a final screenshot.

## Current snapshot

Five fresh containers were run for each case on 27 August 2026, on Apple
Silicon with Docker Linux ARM64. The table reports the median of each metric.
These remain point-in-time measurements; repeat the benchmark before using
them to compare a change. The generated
[`results.json`](../../../packages/benchmark-results/results.json) preserves
all 20 raw samples and the aggregation provenance.

| Workflow             | Estimated tokens | Wall time | CPU time | Peak memory |
| -------------------- | ---------------: | --------: | -------: | ----------: |
| Headless, cold       |              218 |  3,413 ms | 1,794 ms |     381 MiB |
| Headless, warm       |              174 |  3,239 ms | 1,218 ms |     379 MiB |
| Selenium with Python |              410 |  2,828 ms | 1,788 ms |     378 MiB |
| Puppeteer            |              499 |  2,400 ms | 1,849 ms |     367 MiB |

Estimated tokens are `ceil(workflow source bytes / 4)`. They compare the agent
workflow surface, not billed LLM tokens, tool schemas, prompts, or responses.

Headless has the smallest measured agent surface: the warm workflow uses about
58% fewer estimated tokens than Selenium and 65% fewer than Puppeteer. Its
median CPU time is about 32% lower than Selenium and 34% lower than Puppeteer.
Puppeteer is fastest and has the lowest median peak memory; Headless does not
lead those dimensions. The reusable P2 flow command reduces orchestration work
for real agent-driven repeats, but this benchmark retains the comparable
explicit CLI workflow rather than claiming an unmeasured flow speedup.

Both Headless cases now run
`inspect --context actions --task "continue to designer details"` before the
semantic click. The estimated-token count includes that task-aware inspection
command. Selenium and Puppeteer retain their explicit selector-based action
lookup.

## Method

Each workflow uses Chromium 151.0.7922.173 and FFmpeg 5.1.9 to produce the same two
artifacts: an MP4 that tours both pages and a final viewport PNG. Selenium 4.8.3
uses ChromeDriver 151.0.7922.173; Puppeteer Core is 22.15.0. All waits use page load or an
explicit URL condition. Every measured run gets a fresh container. The warm
Headless case starts its host and session before timing; the cold case
includes them.

CPU and peak memory come from the container cgroup. Docker and host-level
overhead are outside those measurements. Artifact byte sizes are not treated as
a performance score because frame timing differs slightly between drivers.

Run the benchmark with:

```sh
./apps/headless/benchmark.sh 5
```

The default output is `packages/benchmark-results/results.json`. Pass a second
argument to write a separate result document without replacing the canonical
snapshot:

```sh
./apps/headless/benchmark.sh 5 /tmp/headless-benchmark.json
```

## VM compatibility result

On 17 July 2026, the Linux ARM64 package was exercised on the Hermes VM
(Ubuntu, Chromium 150.0.7871.46 from the Snap package, FFmpeg 6.1.1). Host
startup, a new session, and the first localhost dashboard visit succeeded. A
second navigation (`reload` or a second visit) stalled on the Snap Chromium
DevTools pipe and eventually showed Chromium's internal error page. No timing
is recorded for that VM because the comparable workflow did not finish.

The Docker benchmark above remains the supported Linux measurement. Runtime
selection now rejects the Snap launcher before opening the DevTools pipe and
reports the supported alternatives. For this VM, use the Docker runtime or a
native distribution Chromium binary and confirm it with `headless runtime`.
