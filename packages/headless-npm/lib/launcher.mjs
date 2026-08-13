import { spawn } from "node:child_process";
import { join } from "node:path";
import { ensureInstalled, InstallError } from "./installer.mjs";

export async function launch(command, argumentsList) {
  try {
    const { directory, release } = await ensureInstalled();
    const relative = command === "headless-mcp" ? release.mcpExecutable : release.executable;
    const child = spawn(join(directory, relative), argumentsList, {
      env: process.env,
      stdio: "inherit",
    });
    const forwardSIGINT = () => { if (!child.killed) child.kill("SIGINT"); };
    const forwardSIGTERM = () => { if (!child.killed) child.kill("SIGTERM"); };
    process.once("SIGINT", forwardSIGINT);
    process.once("SIGTERM", forwardSIGTERM);
    child.once("error", (error) => {
      console.error(`headless npm launcher: ${error.message}`);
      process.exitCode = 70;
    });
    child.once("exit", (code, signal) => {
      process.removeListener("SIGINT", forwardSIGINT);
      process.removeListener("SIGTERM", forwardSIGTERM);
      process.exitCode = code ?? (signal === "SIGINT" ? 130 : 143);
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`headless npm launcher: ${message}`);
    process.exitCode = error instanceof InstallError ? error.exitCode : 70;
  }
}
