"use client";

import {
  CartesianGrid,
  ReferenceLine,
  ResponsiveContainer,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
  ZAxis,
} from "recharts";

type Point = {
  id: string;
  name: string;
  variant: string;
  cpu: number;
  tokens: number;
  wall: number;
  color: string;
  labelDx: number;
  labelDy: number;
  anchor: "start" | "end";
};

/**
 * Efficiency map: CPU time × estimated tokens, bubble size = wall time.
 * Fixed, cited point-in-time snapshot from BENCHMARK.md, not a live query —
 * but plotted through Recharts' real scales, not hand-placed percentages.
 */
const points: Point[] = [
  { id: "headless-warm", name: "Headless", variant: "warm", cpu: 842, tokens: 147, wall: 4753, color: "var(--amber-ink)", labelDx: -38, labelDy: 4, anchor: "end" },
  { id: "headless-cold", name: "Headless", variant: "cold", cpu: 1478, tokens: 194, wall: 5002, color: "var(--teal-ink)", labelDx: 39, labelDy: 4, anchor: "start" },
  { id: "selenium", name: "Selenium", variant: "Python", cpu: 1900, tokens: 410, wall: 3134, color: "#8A9490", labelDx: -18, labelDy: 24, anchor: "end" },
  { id: "puppeteer", name: "Puppeteer", variant: "", cpu: 2441, tokens: 499, wall: 2850, color: "#5B6469", labelDx: -18, labelDy: 24, anchor: "end" },
];

const wallExtent: [number, number] = [Math.min(...points.map((p) => p.wall)), Math.max(...points.map((p) => p.wall))];
const radiusFor = (wall: number) => {
  const t = (wall - wallExtent[0]) / (wallExtent[1] - wallExtent[0] || 1);
  return 13 + t * 13;
};

const xTicks = [0, 700, 1400, 2100, 2700];
const xTickLabels: Record<number, string> = { 0: "0", 700: "700ms", 1400: "1.4s", 2100: "2.1s", 2700: "2.7s" };

function EfficiencyTooltip({ active, payload }: { active?: boolean; payload?: ReadonlyArray<{ payload?: unknown }> }) {
  if (!active || !payload?.length) return null;
  const p = payload[0]?.payload as Point | undefined;
  if (!p) return null;
  return (
    <div className="eff-tooltip">
      <b style={{ color: p.color }}>
        {p.name}
        {p.variant && <i> {p.variant}</i>}
      </b>
      <span>{p.cpu.toLocaleString()}ms cpu</span>
      <span>{p.tokens.toLocaleString()} tokens</span>
      <span>{p.wall.toLocaleString()}ms wall</span>
    </div>
  );
}

function Bubble({ cx, cy, payload }: { cx?: number; cy?: number; payload?: Point }) {
  if (cx === undefined || cy === undefined || !payload) return null;
  const r = radiusFor(payload.wall);
  return (
    <g>
      <circle cx={cx} cy={cy} r={r + 7} fill={payload.color} opacity={0.14} />
      <circle cx={cx} cy={cy} r={r} fill={payload.color} opacity={0.92} />
      <text x={cx + payload.labelDx} y={cy + payload.labelDy} textAnchor={payload.anchor} fontFamily="var(--font-mono), monospace" fontSize={11} fontWeight={600} fill={payload.color}>
        {payload.name}
      </text>
      <text x={cx + payload.labelDx} y={cy + payload.labelDy + 12} textAnchor={payload.anchor} fontFamily="var(--font-mono), monospace" fontSize={9} letterSpacing=".04em" fill="var(--muted)">
        {payload.variant ? payload.variant.toUpperCase() : ""}
      </text>
    </g>
  );
}

export function EfficiencyChart() {
  return (
    <div className="eff-chart" role="img" aria-label="Efficiency map: Headless uses fewer estimated tokens and less CPU time than Selenium and Puppeteer. Its larger bubbles show that the measured wall time was higher.">
      <span className="eff-caption-y">Estimated tokens</span>
      <span className="eff-annotation"><i>most efficient</i> ↙</span>

      <ResponsiveContainer width="100%" height="100%">
        <ScatterChart margin={{ top: 34, right: 24, bottom: 26, left: 8 }}>
          <CartesianGrid stroke="var(--line)" strokeDasharray="3 3" />
          <XAxis type="number" dataKey="cpu" domain={[0, 2700]} ticks={xTicks} tickFormatter={(v) => xTickLabels[v] ?? ""} tick={{ fill: "var(--muted)", fontFamily: "var(--font-mono), monospace", fontSize: 9 }} axisLine={{ stroke: "var(--line)" }} tickLine={false} />
          <YAxis type="number" dataKey="tokens" domain={[0, 600]} ticks={[0, 150, 300, 450, 600]} tick={{ fill: "var(--muted)", fontFamily: "var(--font-mono), monospace", fontSize: 9 }} axisLine={{ stroke: "var(--line)" }} tickLine={false} width={30} />
          <ZAxis type="number" dataKey="wall" range={[13, 26]} />
          <ReferenceLine x={0} stroke="rgba(79,216,196,.5)" />
          <ReferenceLine y={0} stroke="rgba(79,216,196,.5)" />
          <Tooltip content={EfficiencyTooltip} cursor={{ stroke: "var(--line)", strokeDasharray: "3 3" }} />
          <Scatter data={points} shape={<Bubble />} isAnimationActive={false} />
        </ScatterChart>
      </ResponsiveContainer>

      <span className="eff-caption-x">CPU time — bubble size = wall time</span>
    </div>
  );
}
