import { ImageResponse } from "next/og";

// Apple touch icons must be raster, so this is generated at build time rather
// than committed as a binary. Same viewfinder geometry as app/icon.svg.
// iOS applies its own corner mask, so the canvas stays square here.
export const size = { width: 180, height: 180 };
export const contentType = "image/png";

const ARM = 52;
const THICKNESS = 8;
const FRAME = 118;
const STROKE = "#f5f5f2";

// Each bracket is two rounded bars rather than a bordered box. Bordered boxes
// miter at the corner and leave a visible seam, and they cannot reproduce the
// round line caps the mark is drawn with.
export function bracketBars(arm: number, thickness: number) {
  const edges = [
    ["top", "left"],
    ["top", "right"],
    ["bottom", "left"],
    ["bottom", "right"],
  ] as const;
  return edges.flatMap(([vertical, horizontal]) => {
    const common = {
      position: "absolute" as const,
      background: STROKE,
      borderRadius: thickness / 2,
    };
    return [
      { ...common, width: arm, height: thickness, [vertical]: 0, [horizontal]: 0 },
      { ...common, width: thickness, height: arm, [vertical]: 0, [horizontal]: 0 },
    ];
  });
}

export default function AppleIcon() {
  return new ImageResponse(
    (
      <div
        style={{
          display: "flex",
          width: "100%",
          height: "100%",
          alignItems: "center",
          justifyContent: "center",
          backgroundImage: "linear-gradient(160deg, #1c1c24, #050508)",
        }}
      >
        <div style={{ display: "flex", position: "relative", width: FRAME, height: FRAME }}>
          {bracketBars(ARM, THICKNESS).map((style, index) => (
            <div key={index} style={style} />
          ))}
        </div>
      </div>
    ),
    size,
  );
}
