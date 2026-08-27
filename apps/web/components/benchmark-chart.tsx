type Workflow = {
  workflow: string;
  surface: number;
  color: string;
};

const formatRatio = (value: number) => `${value.toFixed(value === 1 ? 0 : 2)}x`;

export function BenchmarkChart({ data }: { data: Workflow[] }) {
  const maximum = Math.max(1, ...data.map((workflow) => workflow.surface));
  const description = `Estimated agent tokens relative to Headless warm: ${data
    .map((workflow) => `${workflow.workflow} ${formatRatio(workflow.surface)}`)
    .join(", ")}. Lower is better.`;

  return (
    <div className="benchmark-bars" role="img" aria-label={description}>
      {data.map((workflow) => (
        <div className="benchmark-bar-row" key={workflow.workflow}>
          <span className="benchmark-bar-label">{workflow.workflow}</span>
          <span className="benchmark-bar-track" aria-hidden="true">
            <span
              className="benchmark-bar-fill"
              style={{
                backgroundColor: workflow.color,
                width: `${(workflow.surface / maximum) * 100}%`,
              }}
            />
          </span>
          <span className="benchmark-bar-value">
            {formatRatio(workflow.surface)}
          </span>
        </div>
      ))}
    </div>
  );
}
