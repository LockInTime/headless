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

type Workflow = {
  workflow: string;
  surface: number;
  color: string;
};

const data: Workflow[] = [
  { workflow: "Headless warm", surface: 1, color: "var(--amber-ink)" },
  { workflow: "Headless cold", surface: 1.32, color: "var(--teal-ink)" },
  { workflow: "Selenium + Python", surface: 2.79, color: "#8A9490" },
  { workflow: "Puppeteer", surface: 3.39, color: "#5B6469" },
];

const formatRatio = (value: number) => `${value.toFixed(value === 1 ? 0 : 2)}×`;

function BenchmarkTooltip({ active, payload }: { active?: boolean; payload?: ReadonlyArray<{ payload?: unknown }> }) {
  if (!active || !payload?.length) return null;
  const workflow = payload[0]?.payload as Workflow | undefined;
  if (!workflow) return null;

  return (
    <div className="chart-tooltip">
      <b style={{ color: workflow.color }}>{workflow.workflow}</b>
      <span>{formatRatio(workflow.surface)} Headless warm&apos;s estimated tokens</span>
    </div>
  );
}

export function BenchmarkChart() {
  return (
    <div
      className="benchmark-chart"
      role="img"
      aria-label="Estimated agent tokens relative to Headless warm: Headless warm 1 times, Headless cold 1.32 times, Selenium with Python 2.79 times, and Puppeteer 3.39 times. Lower is better."
    >
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={data} layout="vertical" margin={{ top: 6, right: 40, bottom: 8, left: 0 }}>
          <CartesianGrid horizontal={false} stroke="var(--line)" strokeDasharray="3 3" />
          <XAxis
            type="number"
            domain={[0, 3.6]}
            ticks={[0, 1, 2, 3]}
            tickFormatter={(value) => `${value}×`}
            axisLine={{ stroke: "var(--line)" }}
            tickLine={false}
          />
          <YAxis type="category" dataKey="workflow" width={120} axisLine={false} tickLine={false} />
          <Tooltip content={BenchmarkTooltip} cursor={{ fill: "rgba(var(--ink-rgb), .04)" }} />
          <Bar dataKey="surface" radius={[0, 3, 3, 0]} barSize={24} isAnimationActive={false}>
            {data.map((workflow) => (
              <Cell key={workflow.workflow} fill={workflow.color} />
            ))}
            <LabelList
              dataKey="surface"
              position="right"
              formatter={(value) => (
                typeof value === "number" ? formatRatio(value) : String(value ?? "")
              )}
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
