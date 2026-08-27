export type WorkflowPoint = {
  workflow: string;
  label: string;
  tokens: number;
  cpuMs: number;
  wallMs: number;
  memoryMiB: number;
  color: string;
};

function formatSeconds(value: number) {
  return `${(value / 1000).toFixed(2)}s`;
}

export function EfficiencyChart({ data }: { data: WorkflowPoint[] }) {
  const maximum = Math.max(1, ...data.map((point) => point.wallMs));
  const description = `Wall time versus CPU time per run: ${data
    .map(
      (point) =>
        `${point.workflow} ${formatSeconds(point.wallMs)} wall and ${formatSeconds(point.cpuMs)} CPU`,
    )
    .join(", ")}.`;

  return (
    <div className="efficiency-bars" role="img" aria-label={description}>
      <div className="efficiency-legend" aria-hidden="true">
        <span>
          <i className="efficiency-key-wall" />Wall time
        </span>
        <span>
          <i className="efficiency-key-cpu" />CPU time
        </span>
      </div>
      {data.map((point) => (
        <div className="efficiency-row" key={point.workflow}>
          <span className="efficiency-label">{point.label}</span>
          <span className="efficiency-tracks">
            <span className="efficiency-track">
              <span
                className="efficiency-fill efficiency-fill-wall"
                style={{ width: `${(point.wallMs / maximum) * 100}%` }}
              />
              <span className="efficiency-value">
                {formatSeconds(point.wallMs)}
              </span>
            </span>
            <span className="efficiency-track">
              <span
                className="efficiency-fill efficiency-fill-cpu"
                style={{ width: `${(point.cpuMs / maximum) * 100}%` }}
              />
              <span className="efficiency-value">
                {formatSeconds(point.cpuMs)}
              </span>
            </span>
          </span>
        </div>
      ))}
    </div>
  );
}
