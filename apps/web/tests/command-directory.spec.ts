import { expect, test } from "@playwright/test";

test.use({ viewport: { width: 375, height: 812 } });

test("command discovery remains usable on a mobile viewport", async ({ page }) => {
  await page.goto("/docs/commands");

  const pageWidth = await page.locator("html").evaluate((element) => ({
    client: element.clientWidth,
    scroll: element.scrollWidth,
  }));
  expect(pageWidth.scroll).toBeLessThanOrEqual(pageWidth.client);

  const filter = page.getByRole("searchbox", { name: "Filter commands" });
  await expect(filter).toBeVisible();
  const bounds = await filter.boundingBox();
  expect(bounds).not.toBeNull();
  expect(bounds?.x).toBeGreaterThanOrEqual(0);
  expect((bounds?.x ?? 0) + (bounds?.width ?? 0)).toBeLessThanOrEqual(375);

  await filter.focus();
  await expect(filter).toBeFocused();
  await filter.pressSequentially("auth login");

  await expect(page.getByRole("status")).toHaveText(/1 of \d+ groups/);
  await expect(page.getByRole("heading", { level: 2 })).toHaveText([
    "Credential vault",
  ]);

  const tocLinks = page.getByRole("navigation", { name: "On this page" }).getByRole("link");
  await expect(tocLinks).toHaveCount(1);
  await expect(tocLinks).toHaveAttribute("href", "#credential-vault");
  await expect(page.locator("#credential-vault")).toBeVisible();

  await filter.fill("not-a-command");
  await expect(page.getByRole("status")).toHaveText(
    "No commands match “not-a-command”.",
  );
  await expect(page.getByRole("navigation", { name: "On this page" })).toHaveCount(0);
  await expect(page.locator("main section")).toHaveCount(0);
});
