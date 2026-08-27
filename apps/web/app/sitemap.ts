import { PRODUCT_DOC_ROUTES } from "@/lib/repository-content.mjs";
import { SITE_URL } from "@/lib/site-metadata";
import type { MetadataRoute } from "next";

export default function sitemap(): MetadataRoute.Sitemap {
  const routes = [
    "/",
    "/docs",
    "/docs/markdown",
    ...PRODUCT_DOC_ROUTES.map(({ href }) => href),
  ];
  return routes.map((path) => ({
    url: `${SITE_URL}${path}`,
    changeFrequency: path === "/" ? "weekly" : "monthly",
    priority: path === "/" ? 1 : path === "/docs" ? 0.9 : 0.7,
  }));
}
