import { spawn } from "node:child_process";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { getComputerHistorySettings } from "../src/settings.js";

interface Check {
  name: string;
  passed: boolean;
  evidence: unknown;
}

const checks: Check[] = [];
const original = JSON.parse(
  await run(resolve("reverse/original-ipc.mjs"), ["snapshot"]),
);
checks.push({
  name: "original IPC API version",
  passed: original.ping?.serverApiVersion === "CodexComputerUseIPC-2",
  evidence: original.ping,
});
checks.push({
  name: "original EventStream maximum duration",
  passed: original.eventStreamStatus?.maxDurationSeconds === 1800,
  evidence: original.eventStreamStatus,
});

const home = await mkdtemp(join(tmpdir(), "open-history-parity-"));
process.env.OPEN_COMPUTER_HISTORY_HOME = home;
const settings = await getComputerHistorySettings();
checks.push({
  name: "default settings match original",
  passed:
    settings.showMenuBarIcon === original.settings.showMenuBarIcon &&
    settings.observation.defaultApplicationBehavior ===
      original.settings.observation.defaultApplicationBehavior &&
    settings.observation.defaultURLBehavior ===
      original.settings.observation.defaultURLBehavior &&
    settings.observation.allowlist.length ===
      original.settings.observation.allowlist.length &&
    settings.observation.blocklist.length ===
      original.settings.observation.blocklist.length,
  evidence: { original: original.settings, open: settings },
});

const collector = await collectorBinary();
const samplePath = (
  await run(collector, ["sample"], {
    OPEN_COMPUTER_HISTORY_HOME: home,
  })
).trim();
const firstLine = (await readFile(samplePath, "utf8")).split(/\r?\n/u)[0]!;
const event = JSON.parse(firstLine);
const topLevelKeys = Object.keys(event).sort();
checks.push({
  name: "event top-level schema",
  passed:
    ["id", "timestamp", "kind"].every((key) => key in event) &&
    !["type", "application", "sessionID", "segmentID"].some(
      (key) => key in event,
    ),
  evidence: topLevelKeys,
});
checks.push({
  name: "nested app/window schema",
  passed:
    event.app?.bundleIdentifier === "org.openhistory.sample" &&
    (event.app?.secureInput ?? false) === false &&
    event.window?.title === "Sample workflow",
  evidence: { app: event.app, window: event.window },
});

const failed = checks.filter((check) => !check.passed);
console.log(JSON.stringify({ passed: failed.length === 0, checks }, null, 2));
if (failed.length) process.exitCode = 1;

async function collectorBinary(): Promise<string> {
  for (const path of [
    resolve("collector/.build/release/open-history"),
    resolve("collector/.build/debug/open-history"),
  ]) {
    try {
      await readFile(path);
      return path;
    } catch {
      // Try the next build.
    }
  }
  throw new Error("Build the collector before running parity checks.");
}

function run(
  executable: string,
  args: string[],
  environment: Record<string, string> = {},
): Promise<string> {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(executable, args, {
      env: { ...process.env, ...environment },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) resolvePromise(stdout);
      else reject(new Error(`${executable} failed: ${stderr}`));
    });
  });
}
