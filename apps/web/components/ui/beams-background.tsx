type BeamsBackgroundProps = {
  className?: string;
};

/** Static gradient field: keeps the beam look without continuous GPU work. */
export function BeamsBackground({ className }: BeamsBackgroundProps) {
  return (
    <div aria-hidden="true" className={className}>
      <div className="light-field" />
      <div className="beam-grid" />
      <div className="beam-vignette" />
    </div>
  );
}
