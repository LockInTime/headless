# Brand assets

The mark is a **viewfinder** — four corner brackets around empty space. It says
what the product is: a frame with no chrome, pointed at a page. Everything below
is the same geometry at different sizes, so there is one shape to keep right.

Canonical path, on a 64-unit grid:

```
M18.875 26.75V18.875H26.75 M37.25 18.875H45.125V26.75
M45.125 37.25V45.125H37.25 M26.75 45.125H18.875V37.25
```

Stroke width `2.875`, round caps and joins. On the 1024-unit macOS icon grid the
same shape is a 420pt box inset at 302pt with 126pt arms and a 46pt stroke.

## Where each asset lives

| Asset | Source | Notes |
| --- | --- | --- |
| Nav brand mark | `apps/web/public/headless-mark.svg` | Stroke-only and transparent. The site uses it as a CSS mask, so its colour comes from `currentColor` — do not add a background to this file. |
| Browser tab icon | `apps/web/app/icon.svg` | The mark on the dark squircle. A favicon renders against unknown backgrounds, so it carries its own. |
| Apple touch icon | `apps/web/app/apple-icon.tsx` | Generated at build time. iOS applies its own corner mask, so the canvas is square. |
| Social card | `apps/web/app/opengraph-image.tsx` | 1200×630, used for `og:image` and Twitter cards. |
| GitHub avatar and preview | `apps/web/scripts/render-brand.mjs` | `pnpm --filter @headless/web brand` → `apps/web/build/brand/` (gitignored). |
| macOS app icon | `apps/headless/tools/make-icon.swift` | Renders the `.icns` during `build.sh`. |

Raster images are **generated, never committed** — the repository media policy
allows binaries only under `docs/qa/evidence/`. Every raster asset above comes
from code, so it can be regenerated at any size without a design tool.

## Why the tab icon is not the bare mark

`public/headless-mark.svg` is stroke-only and picks its colour from a
`prefers-color-scheme` block inside the file. Browsers do not reliably
re-evaluate that for tab icons, so the near-black stroke can disappear against a
dark tab strip. `app/icon.svg` puts the same mark on the dark squircle the macOS
app icon already uses, which reads on any surface and keeps the two platforms
consistent.

## Drawing the brackets in generated images

The generated images draw each bracket as **two rounded bars**, not a div with
two borders. Bordered boxes miter at the corner and leave a visible diagonal
seam, and they cannot reproduce the round line caps of the source path.

## Updating GitHub

GitHub exposes no API for either of these, so both are manual uploads. Generate
the images first:

```sh
pnpm --filter @headless/web brand
```

- **Organisation avatar** — `apps/web/build/brand/avatar-512.png`
  → <https://github.com/organizations/LockInTime/settings/profile>
  Repositories have no icon of their own; they display the owner's avatar, so
  this is what makes the mark show up next to the repo.
- **Repository social preview** — `apps/web/build/brand/social-preview-1280x640.png`
  → repository **Settings → General → Social preview → Upload an image**
  This is the card shown when the repo is linked on Slack, X, or Discord.
