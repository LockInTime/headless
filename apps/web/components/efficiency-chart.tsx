"use client";

import {
  Area,
  CartesianGrid,
  ComposedChart,
  LabelList,
  Legend,
  Line,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

type WorkflowPoint = {
  workflow: string;
  label: string;
  tokens: number;
  cpuMs: number;
  wallMs: number;
  memoryMiB: number;
  color: string;
};

/** P2 single-run benchmark. Source: BENCHMARK.md. */
const data: WorkflowPoint[] = [
  { workflow: "Headless warm", label: "Warm", tokens: 147, cpuMs: 842, wallMs: 4753, memoryMiB: 276, color: "var(--amber-ink)" },
  { workflow: "Headless cold", label: "Cold", tokens: 194, cpuMs: 1478, wallMs: 5002, memoryMiB: 279, color: "var(--teal-ink)" },
  { workflow: "Selenium + Python", label: "Selenium", tokens: 410, cpuMs: 1900, wallMs: 3134, memoryMiB: 280, color: "#8A9490" },
  { workflow: "Puppeteer", label: "Puppeteer", tokens: 499, cpuMs: 2441, wallMs: 2850, memoryMiB: 319, color: "#5B6469" },
];

function formatSeconds(value: number) {
  return `${(value / 1000).toFixed(3)} s`;
}

function cpuShare(point: WorkflowPoint) {
  return Math.round((point.cpuMs / point.wallMs) * 100);
}

function EfficiencyTooltip({ active, payload }: { active?: boolean; payload?: ReadonlyArray<{ payload?: unknown }> }) {
  if (!active || !payload?.length) return null;
  const point = payload[0]?.payload as WorkflowPoint | undefined;
  if (!point) return null;

  return (
    <div className="chart-tooltip">
      <b style={{ color: point.color }}>{point.workflow}</b>
      <span>{formatSeconds(point.wallMs)} wall · {formatSeconds(point.cpuMs)} CPU</span>
      <span>CPU busy {cpuShare(point)}% of the run · {point.memoryMiB} MiB peak</span>
    </div>
  );
}

export function EfficiencyChart() {
  return (
    <div
      className="benchmark-chart"
      role="img"
      aria-label="Wall time versus CPU time per run for four benchmark workflows. Headless warm: 4.753 seconds wall, 842 milliseconds CPU, busy 18 percent of the run. Headless cold: 5.002 seconds wall, 1.478 seconds CPU, busy 30 percent. Selenium with Python: 3.134 seconds wall, 1.9 seconds CPU, busy 61 percent. Puppeteer: 2.85 seconds wall, 2.441 seconds CPU, busy 86 percent. The gap between the two series is time spent waiting, not computing."
    >
      <ResponsiveContainer width="100%" height="100%">
        <ComposedChart data={data} margin={{ top: 28, right: 20, bottom: 4, left: 0 }}>
          <CartesianGrid vertical={false} stroke="var(--line)" strokeDasharray="3 3" />
          <XAxis
            dataKey="label"
            axisLine={{ stroke: "var(--line)" }}
            tickLine={false}
            tickMargin={10}
          />
          <YAxis
            domain={[0, 5500]}
            ticks={[0, 2000, 4000]}
            tickFormatter={(value) => `${value / 1000}s`}
            axisLine={false}
            tickLine={false}
            width={40}
          />
          <Tooltip content={EfficiencyTooltip} cursor={{ stroke: "var(--line)", strokeDasharray: "3 3" }} />
          <Legend
            verticalAlign="top"
            align="right"
            iconType="plainline"
            iconSize={16}
            wrapperStyle={{
              fontFamily: "var(--font-mono), monospace",
              fontSize: 9,
              paddingBottom: 14,
            }}
          />
          <Area
            type="monotone"
            dataKey="wallMs"
            name="Wall time"
            stroke="#5B6469"
            strokeWidth={1.5}
            fill="rgba(91,100,105,.16)"
            isAnimationActive={false}
          />
          <Line
            type="monotone"
            dataKey="cpuMs"
            name="CPU time"
            stroke="var(--amber-ink)"
            strokeWidth={2}
            dot={{ fill: "var(--amber-ink)", stroke: "var(--bg-soft)", strokeWidth: 2, r: 4 }}
            activeDot={{ r: 5 }}
            isAnimationActive={false}
          >
            <LabelList
              dataKey="cpuMs"
              position="bottom"
              offset={10}
              formatter={(value) => (typeof value === "number" ? `${(value / 1000).toFixed(2)}s` : String(value ?? ""))}
              fill="var(--ink-soft)"
              fontFamily="var(--font-mono), monospace"
              fontSize={9}
            />
          </Line>
        </ComposedChart>
      </ResponsiveContainer>
    </div>
  );
}
