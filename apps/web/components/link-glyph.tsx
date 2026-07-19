import {
  ArrowDownIcon,
  ArrowRightIcon,
  ArrowUpRightIcon,
  type LucideIcon,
} from "lucide-react";

import { cn } from "@/lib/utils";

type GlyphKind = "down" | "external" | "forward";

type LinkGlyphProps = {
  kind: GlyphKind;
  className?: string;
};

const icons: Record<GlyphKind, LucideIcon> = {
  down: ArrowDownIcon,
  external: ArrowUpRightIcon,
  forward: ArrowRightIcon,
};

/** Lucide icons (same set shadcn buttons use). */
export function LinkGlyph({ kind, className }: LinkGlyphProps) {
  const Icon = icons[kind];
  return (
    <Icon
      aria-hidden
      data-kind={kind}
      data-icon="inline-end"
      strokeWidth={1.75}
      className={cn("link-glyph size-4", className)}
    />
  );
}
