#!/bin/sh
set -eu

chromeless --session bench visit "$BENCH_URL" >/dev/null
chromeless --session bench record start --fps 5 >/dev/null
chromeless --session bench tour --full-page --pace 5000 >/dev/null
chromeless --session bench click --role button --name Continue >/dev/null
chromeless --session bench wait --url /next --text 'Designer details' --settled --timeout 10000 >/dev/null
chromeless --session bench tour --full-page --pace 5000 >/dev/null
chromeless --session bench record stop --output flow.mp4 >/dev/null
chromeless --session bench screenshot --output final.png >/dev/null
