import { accessSync, readFileSync } from "node:fs";
import { dirname, extname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { transformSync } from "next/dist/build/swc/index.js";

const webRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourceExtensions = ["", ".tsx", ".ts", ".jsx", ".js", ".mjs"];

export function resolve(specifier, context, nextResolve) {
  if (!specifier.startsWith("@/")) return nextResolve(specifier, context);

  const sourcePath = join(webRoot, specifier.slice(2));
  for (const extension of sourceExtensions) {
    const candidate = `${sourcePath}${extension}`;
    try {
      accessSync(candidate);
      return { shortCircuit: true, url: pathToFileURL(candidate).href };
    } catch {
      // Try the next supported source extension.
    }
  }

  throw new Error(`Cannot resolve web source import: ${specifier}`);
}

export function load(url, context, nextLoad) {
  const extension = extname(new URL(url).pathname);
  if (extension === ".json") {
    const source = readFileSync(fileURLToPath(url), "utf8");
    return {
      format: "module",
      shortCircuit: true,
      source: `export default ${source};`,
    };
  }
  if (extension !== ".tsx" && extension !== ".ts") {
    return nextLoad(url, context);
  }

  const filename = fileURLToPath(url);
  const source = readFileSync(filename, "utf8");
  const output = transformSync(source, {
    filename,
    sourceMaps: false,
    jsc: {
      parser: {
        syntax: "typescript",
        tsx: extension === ".tsx",
      },
      target: "es2022",
      transform: {
        react: {
          runtime: "automatic",
        },
      },
    },
    module: {
      type: "es6",
    },
  });

  return {
    format: "module",
    shortCircuit: true,
    source: output.code,
  };
}
