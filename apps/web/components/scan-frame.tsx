import Image from "next/image";
import dashboard from "@/public/scan-dashboard.png";

/**
 * Real coordinates from a real `headless inspect --interactive` run against
 * a live local page (viewport 1152×669) — not hand-drawn placeholders.
 * Percentages below are those pixel bounds divided by the viewport size.
 */
type Tag = {
  id: string;
  role: string;
  name: string;
  box: { top: number; left: number; width: number; height: number };
  label: { top?: number; bottom?: number; left?: number; right?: number; align: "left" | "right" };
  delay: string;
  safe?: boolean;
};

const tags: Tag[] = [
  { id: "@e1", role: "link", name: "Designers", box: { top: 15.4, left: 1.4, width: 15.2, height: 5.1 }, label: { top: 22, left: 1.4, align: "left" }, delay: "0.75s" },
  { id: "@e2", role: "textbox", name: "Search", box: { top: 4.3, left: 75.3, width: 21.7, height: 5.2 }, label: { top: 11.5, right: 2.8, align: "right" }, delay: "0.42s" },
  { id: "@e3", role: "button", name: "Continue", box: { top: 91.9, left: 86.2, width: 9.2, height: 5.2 }, label: { bottom: 9, right: 4.6, align: "right" }, delay: "2.5s", safe: true },
];

/** Signature hero graphic: a real page, actually inspected by Headless, with live @ref tags. */
export function ScanFrame() {
  return (
    <div className="scan-frame" role="img" aria-label="Headless inspecting a real local page: a sidebar link, a search field, and a Continue button each receive a live semantic reference tag from a real accessibility-tree query">
      <div className="scan-frame-head">
        <span className="scan-dot" />
        <span className="scan-dot" />
        <span className="scan-dot" />
        <p>127.0.0.1/designers/dashboard</p>
        <b>inspect --interactive</b>
      </div>
      <div className="scan-canvas">
        <Image src={dashboard} alt="" fill sizes="(max-width: 980px) 100vw, 50vw" priority className="scan-canvas-img" />
        <div className="scan-line" aria-hidden="true" />

        {tags.map((tag) => (
          <div key={tag.id} className="scan-box" style={{ top: `${tag.box.top}%`, left: `${tag.box.left}%`, width: `${tag.box.width}%`, height: `${tag.box.height}%`, animationDelay: tag.delay, ...(tag.safe ? { borderColor: "var(--teal)" } : {}) }} />
        ))}

        {tags.map((tag) => (
          <div
            key={`${tag.id}-label`}
            className={`scan-tag scan-tag-${tag.label.align}${tag.safe ? " scan-tag-safe" : ""}`}
            style={{
              top: tag.label.top !== undefined ? `${tag.label.top}%` : undefined,
              bottom: tag.label.bottom !== undefined ? `${tag.label.bottom}%` : undefined,
              left: tag.label.left !== undefined ? `${tag.label.left}%` : undefined,
              right: tag.label.right !== undefined ? `${tag.label.right}%` : undefined,
              animationDelay: tag.delay,
            }}
          >
            <span className="scan-tag-pill">
              <b>{tag.id}</b>
              {tag.role} <i>&ldquo;{tag.name}&rdquo;</i>
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
