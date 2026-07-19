type BeamsBackgroundProps = {
  className?: string;
};

/** Static grid + vignette behind the hero. */
export function BeamsBackground({ className }: BeamsBackgroundProps) {
  return (
    <div aria-hidden="true" className={className}>
      <div className="beam-grid" />
      <div className="beam-vignette" />
    </div>
  );
}
