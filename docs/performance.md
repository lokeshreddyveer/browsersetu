# Performance measurements

Measured 17 October 2026 on the author's Mac (Apple Silicon, macOS 27 beta), debug build, content blocking on, home network. Numbers are for comparing one build with the next on
the same machine. They are **not** a comparison with Safari or any other browser, and they cover the app's own process only: WebKit's page processes are separate and are not counted.

## Many tabs (`TabScalingTests`)
| Tabs (with a real page) | Open all | Switch, average / worst | App-process memory growth | Asleep after a critical-memory event |
|---|---|---|---|---|
| 10 (10) | 183 ms | 0.11 / 0.33 ms | 0.9 MB | 8 |
| 50 (15) | 347 ms | 0.19 / 0.39 ms | 6.5 MB | 13 |
| 100 (15) | 499 ms | 0.36 / 0.60 ms | 12.3 MB | 13 |

The tab in front is never put to sleep, a sleeping tab wakes with its address when it is chosen again, and the rest of a large tab set stays blank until it is opened.
The test keeps 15 real pages live in the 50- and 100-tab runs; the cost of 100 fully loaded pages was not measured.

## Real pages (`RealPagePerformanceTests`, runs only with `TEST_RUNNER_BS_REAL_PAGES=1`)
Time until the page stops loading, first visit, cold cache: Hacker News 507 ms, BBC 771 ms, wikipedia.org 779 ms, apple.com 790 ms, GitHub 1.03 s, a long Wikipedia article 1.83 s.
App-process memory after the six pages: +4.7 MB. One run each; network time varies.

## Other measured moments
Blank-profile start about 22 ms, new tab about 2 ms, switching tabs 0.04 ms, address-bar suggestions under 1 ms, a new tab while a 4,000-row page is open holds the window 8 to 13 ms.

## Not measured
Per-tab CPU and memory (WebKit reports neither for a page), a Safari comparison, battery, thermal behaviour, and 100 fully loaded tabs.

## How the browser protects itself
Memory pressure and heat (serious or critical thermal state) put older inactive tabs to sleep; Memory Saver also does it on a timer; Low Power Mode can switch to the saver; the tab in front, private tabs, tabs playing media or in use by the camera or microphone, and pinned tabs when asked are never released.
