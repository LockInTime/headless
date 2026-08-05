// Renders the square brand images GitHub needs — an organisation avatar and a
// repository social preview — into build/brand/, which is gitignored.
//
// GitHub exposes no API for either upload, so these are generated on demand and
// uploaded by hand. Keeping the generator in the repo means the images stay
// reproducible without committing binaries.
//
//   pnpm --filter @headless/web brand
import { mkdir, writeFile } from "node:fs/promises";
import { ImageResponse } from "next/og.js";

const OUT = new URL("../build/brand/", import.meta.url);
const STROKE = "#f5f5f2";

// Each bracket is two rounded bars rather than a bordered box: bordered boxes
// miter at the corner and leave a seam, and cannot reproduce the round line
// caps the mark is drawn with.
function viewfinder({ frame, arm, thickness }) {
  const edges = [
    ["top", "left"],
    ["top", "right"],
    ["bottom", "left"],
    ["bottom", "right"],
  ];
  const bars = edges.flatMap(([vertical, horizontal]) => {
    const common = { position: "absolute", background: STROKE, borderRadius: thickness / 2 };
    return [
      { ...common, width: arm, height: thickness, [vertical]: 0, [horizontal]: 0 },
      { ...common, width: thickness, height: arm, [vertical]: 0, [horizontal]: 0 },
    ];
  });
  return {
    type: "div",
    props: {
      style: { display: "flex", position: "relative", width: frame, height: frame },
      children: bars.map((style, key) => ({ type: "div", key, props: { style } })),
    },
  };
}

function canvas(children, extra = {}) {
  return {
    type: "div",
    props: {
      style: {
        display: "flex",
        width: "100%",
        height: "100%",
        alignItems: "center",
        justifyContent: "center",
        backgroundImage: "linear-gradient(160deg, #1c1c24, #050508)",
        color: STROKE,
        ...extra,
      },
      children,
    },
  };
}

async function render(name, element, size) {
  const response = new ImageResponse(element, size);
  const buffer = Buffer.from(await response.arrayBuffer());
  await writeFile(new URL(name, OUT), buffer);
  console.log(`${name}  ${size.width}x${size.height}  ${buffer.length} bytes`);
}

await mkdir(OUT, { recursive: true });

// Organisation avatar. GitHub wants a square image of at least 500px.
await render(
  "avatar-512.png",
  canvas([viewfinder({ frame: 300, arm: 132, thickness: 26 })]),
  { width: 512, height: 512 },
);

// Repository social preview. GitHub renders it at 1280x640.
await render(
  "social-preview-1280x640.png",
  canvas(
    [
      {
        type: "div",
        props: {
          style: { display: "flex", flexDirection: "column", alignItems: "center", gap: 30 },
          children: [
            viewfinder({ frame: 170, arm: 74, thickness: 14 }),
            { type: "div", props: { style: { display: "flex", fontSize: 78, letterSpacing: -2 }, children: "headless" } },
            {
              type: "div",
              props: {
                style: { display: "flex", fontSize: 34, color: "#a5a5ad" },
                children: "Give your agent a real browser.",
              },
            },
          ],
        },
      },
    ],
    { flexDirection: "column" },
  ),
  { width: 1280, height: 640 },
);

console.log(`\nWrote to ${new URL(".", OUT).pathname}`);
