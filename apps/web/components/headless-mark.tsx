type HeadlessMarkProps = { className?: string };

export function HeadlessMark({ className }: HeadlessMarkProps) {
  return <span className={className} role="img" aria-label="Headless mark" />;
}
