"use client";

import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  LabelList,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

type Runtime = {
  workflow: string;
  ratio: number;
  color: string;
};

/** P2 benchmark CPU time vs Headless warm (842 ms). Source: BENCHMARK.md */
const data: Runtime[] = [
  { workflow: "Headless warm", ratio: 1, color: "var(--amber-ink)" },
  { workflow: "Headless cold", ratio: 1.76, color: "var(--teal-ink)" },
  { workflow: "Selenium + Python", ratio: 2.26, color: "#8A9490" },
  { workflow: "Puppeteer", ratio: 2.9, color: "#5B6469" },
];

const formatRatio = (value: number) => `${value.toFixed(value === 1 ? 0 : 2)}×`;

function RuntimeTooltip({ active, payload }: { active?: boolean; payload?: ReadonlyArray<{ payload?: unknown }> }) {
  if (!active || !payload?.length) return null;
  const row = payload[0]?.payload as Runtime | undefined;
  if (!row) return null;

  return (
    <div className="chart-tooltip">
      <b style={{ color: row.color }}>{row.workflow}</b>
      <span>{formatRatio(row.ratio)} Headless warm&apos;s CPU time</span>
    </div>
  );
}

/** CPU time per benchmark run, normalized to Headless warm = 1×. */
export function RuntimeChart() {
  return (
    <div
      className="benchmark-chart"
      role="img"
      aria-label="CPU time per run relative to Headless warm: Headless warm 1 times, Headless cold 1.76 times, Selenium with Python 2.26 times, and Puppeteer 2.9 times. Lower is better."
    >
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} layout="vertical" margin={{ top: 6, right: 40, bottom: 8, left: 0 }}>
          <CartesianGrid horizontal={false} stroke="var(--line)" strokeDasharray="3 3" />
          <XAxis
            type="number"
            domain={[0, 3.2]}
            ticks={[0, 1, 2, 3]}
            tickFormatter={(value) => `${value}×`}
            axisLine={{ stroke: "var(--line)" }}
            tickLine={false}
          />
          <YAxis type="category" dataKey="workflow" width={120} axisLine={false} tickLine={false} />
          <Tooltip content={RuntimeTooltip} cursor={{ fill: "rgba(var(--ink-rgb), .04)" }} />
          <Bar dataKey="ratio" radius={[0, 3, 3, 0]} barSize={24} isAnimationActive={false}>
            {data.map((row) => (
              <Cell key={row.workflow} fill={row.color} />
            ))}
            <LabelList
              dataKey="ratio"
              position="right"
              formatter={(value) => (typeof value === "number" ? formatRatio(value) : String(value ?? ""))}
              fill="var(--ink-soft)"
              fontFamily="var(--font-mono), monospace"
              fontSize={10}
            />
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

/** @deprecated Generic Recharts sample — use RuntimeChart. */
export const BandedChart = RuntimeChart;

/** @deprecated Use RuntimeChart. */
export const EfficiencyChart = RuntimeChart;
