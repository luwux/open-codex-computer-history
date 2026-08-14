import net from "node:net";
import { chmod, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { historyHome, clearHistoryRequest } from "./history-store.js";
import {
  eventStreamStatus,
  pauseRecorder,
  recorderStatus,
  resumeRecorder,
  stopRecorder,
} from "./runtime-control.js";
import {
  computerHistorySettingsSchema,
  getComputerHistorySettings,
  updateComputerHistorySettings,
} from "./settings.js";

const apiVersion = "CodexComputerUseIPC-2";
const maximumFrameSize = 8 * 1024 * 1024;

export async function startNativeIPCServer(): Promise<net.Server> {
  const socketPath =
    process.env.OPEN_HISTORY_NATIVE_PIPE_PATH ??
    join(historyHome(), "IPC", "computeruse.sock");
  await mkdir(dirname(socketPath), { recursive: true });
  await rm(socketPath, { force: true });

  const server = net.createServer((socket) => {
    let buffer = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4) {
        const length = buffer.readUInt32LE(0);
        if (length > maximumFrameSize) {
          socket.destroy(new Error(`IPC frame exceeds ${maximumFrameSize} bytes`));
          return;
        }
        if (buffer.length < 4 + length) return;
        const payload = buffer.subarray(4, 4 + length).toString("utf8");
        buffer = buffer.subarray(4 + length);
        void handleFrame(socket, payload);
      }
    });
  });
  await new Promise<void>((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.off("error", reject);
      resolvePromise();
    });
  });
  await chmod(socketPath, 0o600);
  return server;
}

export async function dispatchNativeRequest(
  method: string,
  params: Record<string, unknown>,
): Promise<unknown> {
  if (params.clientApiVersion !== apiVersion) {
    throw ipcError(
      -10013,
      "The Computer Use server and client have a version mismatch.",
    );
  }
  if (method === "ping") return { serverApiVersion: apiVersion };
  if (method !== "request") throw ipcError(-32601, `Unknown method: ${method}`);

  const requestType = String(params.requestType ?? "");
  const request =
    typeof params.request === "object" && params.request
      ? (params.request as Record<string, unknown>)
      : {};
  switch (requestType) {
    case "ComputerUseIPCSkysightStatusRequest":
      return recorderStatus();
    case "ComputerUseIPCSkysightGetSettingsRequest":
      return getComputerHistorySettings();
    case "ComputerUseIPCSkysightUpdateSettingsRequest":
      return updateComputerHistorySettings(
        computerHistorySettingsSchema.parse(request.settings),
      );
    case "ComputerUseIPCSkysightPauseRequest":
      return pauseRecorder();
    case "ComputerUseIPCSkysightResumeRequest":
    case "ComputerUseIPCSkysightStartRequest":
      return resumeRecorder();
    case "ComputerUseIPCSkysightStopRequest":
      return stopRecorder();
    case "ComputerUseIPCSkysightClearHistoryRequest":
      await clearHistoryRequest(clearRequest(request));
      return recorderStatus();
    case "ComputerUseIPCEventStreamStatusRequest":
      return eventStreamStatus();
    case "ComputerUseIPCEventStreamStartRequest":
      return eventStreamStatusAfter(resumeRecorder());
    case "ComputerUseIPCEventStreamStopRequest":
      return eventStreamStatusAfter(stopRecorder());
    default:
      throw ipcError(-32602, `Unhandled request type: ${requestType}`);
  }
}

async function handleFrame(socket: net.Socket, payload: string): Promise<void> {
  let request: {
    id?: number;
    jsonrpc?: string;
    method?: string;
    params?: Record<string, unknown>;
  };
  try {
    request = JSON.parse(payload);
  } catch {
    writeFrame(socket, {
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: "Parse error" },
    });
    return;
  }
  try {
    const result = await dispatchNativeRequest(
      String(request.method ?? ""),
      request.params ?? {},
    );
    writeFrame(socket, { jsonrpc: "2.0", id: request.id ?? null, result });
  } catch (error) {
    const code =
      error instanceof Error && "code" in error
        ? Number((error as Error & { code: number }).code)
        : -32603;
    writeFrame(socket, {
      jsonrpc: "2.0",
      id: request.id ?? null,
      error: {
        code,
        message: error instanceof Error ? error.message : String(error),
      },
    });
  }
}

function writeFrame(socket: net.Socket, response: unknown): void {
  const body = Buffer.from(JSON.stringify(response), "utf8");
  const frame = Buffer.alloc(4 + body.length);
  frame.writeUInt32LE(body.length, 0);
  body.copy(frame, 4);
  socket.write(frame);
}

function clearRequest(request: Record<string, unknown>) {
  const scope = String(request.scope);
  switch (scope) {
    case "last_ten_minutes":
      return { scope: "last_10_minutes" as const };
    case "last_hour":
      return { scope: "last_hour" as const };
    case "last_day":
      return { scope: "last_day" as const };
    case "today":
      return { scope: "today" as const };
    case "application_session":
      return { scope: "application_session" as const };
    case "interval": {
      const interval =
        typeof request.interval === "object" && request.interval
          ? (request.interval as Record<string, unknown>)
          : {};
      const start = new Date(String(interval.start ?? ""));
      const end = new Date(String(interval.end ?? ""));
      if (
        !Number.isFinite(start.getTime()) ||
        !Number.isFinite(end.getTime()) ||
        start >= end
      ) {
        throw ipcError(-32602, "Invalid Computer History clear interval.");
      }
      return { scope: "interval" as const, interval: { start, end } };
    }
    case "all":
      return { scope: "all" as const };
    default:
      throw ipcError(-32602, `Unsupported clear scope: ${scope}`);
  }
}

async function eventStreamStatusAfter(
  operation: Promise<unknown>,
): Promise<unknown> {
  await operation;
  return eventStreamStatus();
}

function ipcError(code: number, message: string): Error & { code: number } {
  return Object.assign(new Error(message), { code });
}
