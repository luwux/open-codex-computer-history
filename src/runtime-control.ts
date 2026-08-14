import { spawn } from "node:child_process";
import { access, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { historyHome } from "./history-store.js";

export type RecorderState = "stopped" | "running" | "paused";

export interface RecorderRuntimeStatus {
  state: RecorderState;
  processIdentifier?: number;
  eventStreamRootPath: string;
  currentSegmentEventsPath?: string;
  currentSegmentMetadataPath?: string;
  suppressedEventsPath?: string;
  startedAt?: string;
  endedAt?: string;
}

export async function recorderStatus(): Promise<RecorderRuntimeStatus> {
  const home = historyHome();
  try {
    const parsed = JSON.parse(
      await readFile(join(home, "runtime.json"), "utf8"),
    ) as RecorderRuntimeStatus;
    if (
      parsed.state !== "stopped" &&
      (!parsed.processIdentifier || !isProcessAlive(parsed.processIdentifier))
    ) {
      return stoppedStatus(home, parsed.endedAt);
    }
    return parsed;
  } catch {
    return stoppedStatus(home);
  }
}

export async function pauseRecorder(): Promise<RecorderRuntimeStatus> {
  const status = await recorderStatus();
  if (status.state === "stopped") {
    throw new Error("Computer History is stopped.");
  }
  await writeControl("paused");
  return waitForState("paused");
}

export async function resumeRecorder(): Promise<RecorderRuntimeStatus> {
  const status = await recorderStatus();
  await writeControl("running");
  if (status.state === "stopped") {
    const binary = await collectorBinary();
    const child = spawn(binary, ["record", "--no-prompt"], {
      detached: true,
      env: {
        ...process.env,
        OPEN_COMPUTER_HISTORY_HOME: historyHome(),
      },
      stdio: "ignore",
    });
    child.unref();
  }
  return waitForState("running");
}

export async function stopRecorder(): Promise<RecorderRuntimeStatus> {
  const status = await recorderStatus();
  if (status.state === "stopped" || !status.processIdentifier) return status;
  process.kill(status.processIdentifier, "SIGTERM");
  return waitForState("stopped");
}

export async function eventStreamStatus() {
  const status = await recorderStatus();
  let sessionID: string | undefined;
  if (status.currentSegmentMetadataPath) {
    try {
      const metadata = JSON.parse(
        await readFile(status.currentSegmentMetadataPath, "utf8"),
      ) as { id?: string };
      sessionID = metadata.id;
    } catch {
      // The status remains useful while metadata is temporarily unavailable.
    }
  }
  return {
    isRecording: status.state === "running",
    ...(sessionID ? { sessionID } : {}),
    ...(status.currentSegmentEventsPath
      ? {
          sessionDirectoryPath: dirname(status.currentSegmentEventsPath),
          eventsPath: status.currentSegmentEventsPath,
        }
      : {}),
    ...(status.currentSegmentMetadataPath
      ? { metadataPath: status.currentSegmentMetadataPath }
      : {}),
    ...(status.suppressedEventsPath
      ? { suppressedEventsPath: status.suppressedEventsPath }
      : {}),
    ...(status.startedAt ? { startedAt: status.startedAt } : {}),
    ...(status.endedAt ? { endedAt: status.endedAt } : {}),
    maxDurationSeconds: 1800,
  };
}

async function writeControl(
  state: RecorderState,
  resumeAt?: Date,
): Promise<void> {
  const path = join(historyHome(), "control.json");
  const temporaryPath = `${path}.tmp-${process.pid}`;
  await mkdir(historyHome(), { recursive: true });
  await writeFile(
    temporaryPath,
    `${JSON.stringify(
      {
        state,
        updatedAt: new Date().toISOString(),
        ...(resumeAt ? { resumeAt: resumeAt.toISOString() } : {}),
      },
      null,
      2,
    )}\n`,
    { mode: 0o600 },
  );
  await rename(temporaryPath, path);
}

async function waitForState(expected: RecorderState): Promise<RecorderRuntimeStatus> {
  const deadline = Date.now() + 8_000;
  let latest = await recorderStatus();
  while (Date.now() < deadline) {
    latest = await recorderStatus();
    if (latest.state === expected) return latest;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  throw new Error(
    `Computer History did not reach ${expected}; current state is ${latest.state}.`,
  );
}

async function collectorBinary(): Promise<string> {
  const candidates = [
    process.env.OPEN_HISTORY_COLLECTOR_BIN,
    resolve("collector/.build/release/open-history"),
    resolve("collector/.build/debug/open-history"),
  ].filter((candidate): candidate is string => Boolean(candidate));
  for (const candidate of candidates) {
    try {
      await access(candidate);
      return candidate;
    } catch {
      // Try the next known build location.
    }
  }
  throw new Error(
    "The open-history collector is not built. Run `npm run collector:build`.",
  );
}

function isProcessAlive(processIdentifier: number): boolean {
  try {
    process.kill(processIdentifier, 0);
    return true;
  } catch {
    return false;
  }
}

function stoppedStatus(
  home: string,
  endedAt?: string,
): RecorderRuntimeStatus {
  return {
    state: "stopped",
    eventStreamRootPath: home,
    ...(endedAt ? { endedAt } : {}),
  };
}
