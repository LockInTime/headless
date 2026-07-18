#!/bin/sh
set -eu

headless --session bench visit "$BENCH_URL" >/dev/null
headless --session bench record start --fps 5 >/dev/null
headless --session bench tour --full-page --pace 5000 >/dev/null
headless --session bench click --role button --name Continue >/dev/null
headless --session bench wait --url /next --text 'Designer details' --settled --timeout 10000 >/dev/null
headless --session bench tour --full-page --pace 5000 >/dev/null
headless --session bench record stop --output flow.mp4 >/dev/null
headless --session bench screenshot --output final.png >/dev/null
