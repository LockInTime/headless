# P2 benchmark

This benchmark compares the code an agent needs to visit the fixture dashboard,
record through the `Continue` transition, and save a final screenshot.

## Current snapshot

One fresh container was run for each case on 17 July 2026, on Apple Silicon
with Docker Linux ARM64. These are point-in-time measurements, not medians;
repeat the benchmark before using them to compare a change.

| Workflow | Estimated tokens | Wall time | CPU time | Peak memory |
| --- | ---: | ---: | ---: | ---: |
| Headless, cold | 194 | 5,002 ms | 1,478 ms | 279 MiB |
| Headless, warm | 147 | 4,753 ms | 842 ms | 276 MiB |
| Selenium with Python | 410 | 3,134 ms | 1,900 ms | 280 MiB |
| Puppeteer | 499 | 2,850 ms | 2,441 ms | 319 MiB |

Estimated tokens are `ceil(workflow source bytes / 4)`. They compare the agent
workflow surface, not billed LLM tokens, tool schemas, prompts, or responses.

Headless has the smallest agent surface: the warm workflow uses about 64%
fewer estimated tokens than Selenium and 71% fewer than Puppeteer. In this
single sample it also had the lowest CPU time and memory peak. Puppeteer was
fastest. The reusable P2 flow command reduces orchestration work for real
agent-driven repeats, but this benchmark retains the comparable explicit CLI
workflow rather than claiming an unmeasured flow speedup.

## Method

Each workflow uses Chromium 150 and FFmpeg 5.1 to produce the same two
artifacts: an MP4 that tours both pages and a final viewport PNG. Selenium 4.8.3
uses ChromeDriver 150; Puppeteer Core is 22.15.0. All waits use page load or an
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
