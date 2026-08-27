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

const formatRatio = (value: number) => `${value.toFixed(value === 1 ? 0 : 2)}×`;

function BenchmarkTooltip({
  active,
  payload,
}: {
  active?: boolean;
  payload?: ReadonlyArray<{ payload?: unknown }>;
}) {
  if (!active || !payload?.length) return null;
  const workflow = payload[0]?.payload as Workflow | undefined;
  if (!workflow) return null;

  return (
    <div className="chart-tooltip">
      <b style={{ color: workflow.color }}>{workflow.workflow}</b>
      <span>
        {formatRatio(workflow.surface)} Headless warm&apos;s estimated tokens
      </span>
    </div>
  );
}

export function BenchmarkChart({ data }: { data: Workflow[] }) {
  const ariaLabel = `Estimated agent tokens relative to Headless warm: ${data
    .map((workflow) => `${workflow.workflow} ${formatRatio(workflow.surface)}`)
    .join(", ")}. Lower is better.`;
  const maximum = Math.max(...data.map((workflow) => workflow.surface));

  return (
    <div className="benchmark-chart" role="img" aria-label={ariaLabel}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart
          data={data}
          layout="vertical"
          margin={{ top: 6, right: 40, bottom: 8, left: 0 }}
        >
          <CartesianGrid
            horizontal={false}
            stroke="var(--line)"
            strokeDasharray="3 3"
          />
          <XAxis
            type="number"
            domain={[0, Math.ceil(maximum * 1.1)]}
            allowDecimals={false}
            tickFormatter={(value) => `${value}×`}
            axisLine={{ stroke: "var(--line)" }}
            tickLine={false}
          />
          <YAxis
            type="category"
            dataKey="workflow"
            width={120}
            axisLine={false}
            tickLine={false}
          />
          <Tooltip
            content={BenchmarkTooltip}
            cursor={{ fill: "rgba(var(--ink-rgb), .04)" }}
          />
          <Bar
            dataKey="surface"
            radius={[0, 3, 3, 0]}
            barSize={24}
            isAnimationActive={false}
          >
            {data.map((workflow) => (
              <Cell key={workflow.workflow} fill={workflow.color} />
            ))}
            <LabelList
              dataKey="surface"
              position="right"
              formatter={(value) =>
                typeof value === "number"
                  ? formatRatio(value)
                  : String(value ?? "")
              }
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
