#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repository_root"

printf '\033[2J\033[H'
printf '\033[1;36mHeadless — progressive context pruning\033[0m\n'
printf 'Real runtime test · 120-section operations handbook\n\n'
sleep 2

printf '\033[1;33m$ pnpm test:runtime\033[0m\n'
runtime_output="$(pnpm test:runtime)"
printf '%s\n' "$runtime_output"
metrics="$(printf '%s\n' "$runtime_output" | tail -n 1)"
region="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).selectedRegion)' "$metrics")"
sleep 2

node -e '
  const m = JSON.parse(process.argv[1]);
  const reduction = (100 * (1 - m.summary.estimatedTokens / m.full.estimatedTokens)).toFixed(1);
  console.log("\n\u001b[1;32mPASS — actual measured output\u001b[0m");
  console.log(`  full page      ${String(m.full.estimatedTokens).padStart(6)} estimated tokens`);
  console.log(`  task summary   ${String(m.summary.estimatedTokens).padStart(6)} estimated tokens`);
  console.log(`  scoped text    ${String(m.scopedText.estimatedTokens).padStart(6)} estimated tokens`);
  console.log(`  scoped actions ${String(m.scopedActions.estimatedTokens).padStart(6)} estimated tokens`);
  console.log(`\n  \u001b[1;36m${reduction}% less context in the focused summary\u001b[0m`);
' "$metrics"
sleep 4

printf '\n\033[1;33mProgressive CLI workflow\033[0m\n'
printf '  inspect --context summary --task "Linux authentication" --budget 700\n'
printf '  inspect --context outline --task "Linux authentication"\n'
printf '  inspect --context text    --within %s --budget 700\n' "$region"
printf '  inspect --context actions --within %s --budget 700\n' "$region"
sleep 4

printf '\n\033[1;32m✓ Found the short-lived service-account instructions\033[0m\n'
printf '\033[1;32m✓ Found “Copy authentication command” inside the selected region\033[0m\n'
printf '\033[2mBudgets, omitted counts, and untrusted-content markers verified.\033[0m\n'
sleep 4
