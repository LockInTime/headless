export function plainText(markdown: string) {
  return markdown
    .replace(/\[([^\]]+)]\([^)]+\)/g, "$1")
    .replaceAll("`", "")
    .replaceAll("**", "")
    .replaceAll("~~", "")
    .replace(/_([^_]+)_/g, "$1");
}
