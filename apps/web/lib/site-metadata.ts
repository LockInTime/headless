import type { Metadata } from "next";

export const SITE_URL = "https://headless-web-pi.vercel.app";

export function docsMetadata(
  title: string,
  description: string,
  path: string,
): Metadata {
  const fullTitle = `${title} | Headless`;
  return {
    title: fullTitle,
    description,
    alternates: { canonical: path },
    openGraph: {
      title: fullTitle,
      description,
      url: path,
      siteName: "Headless",
      type: "website",
    },
    twitter: { card: "summary_large_image", title: fullTitle, description },
  };
}
