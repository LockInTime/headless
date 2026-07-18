"use client";

import { Bar, EvilBarChart, Grid, Tooltip, XAxis, YAxis } from "@/components/evilcharts/charts/bar-chart";
import type { ChartConfig } from "@/components/evilcharts/ui/chart";

const data = [
  { workflow: "Headless warm", surface: 1 },
  { workflow: "Headless cold", surface: 1.32 },
  { workflow: "Selenium + Python", surface: 2.79 },
  { workflow: "Puppeteer", surface: 3.39 },
];

const config = {
  surface: {
    label: "Workflow surface",
    colors: { light: ["#d7ff3f", "#adca52", "#71796c", "#545b52"] },
  },
} satisfies ChartConfig;

export function BenchmarkChart() {
  return <EvilBarChart data={data} config={config} layout="horizontal" animationType="none" barRadius={2} className="benchmark-chart">
    <Grid stroke="rgba(231,233,222,.12)" />
    <XAxis domain={[0, 3.5]} ticks={[0, 1, 2, 3]} tickFormatter={(value) => `${value}×`} />
    <YAxis dataKey="workflow" width={118} />
    <Tooltip variant="frosted-glass" roundness="md" />
    <Bar dataKey="surface" variant="gradient" enableHoverHighlight />
  </EvilBarChart>;
}
