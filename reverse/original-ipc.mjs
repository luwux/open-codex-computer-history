#!/usr/bin/env node

import net from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

const apiVersion = "CodexComputerUseIPC-2";
const socketPath =
  process.env.SKY_CUA_SERVICE_NATIVE_PIPE_PATH ??
  join(
    homedir(),
    "Library",
    "Group Containers",
    "2DC432GLL2.com.openai.sky.CUAService",
    "IPC",
    "computeruse.sock",
  );

const requestTypes = {
  status: "ComputerUseIPCSkysightStatusRequest",
  settings: "ComputerUseIPCSkysightGetSettingsRequest",
  eventStreamStatus: "ComputerUseIPCEventStreamStatusRequest",
  start: "ComputerUseIPCSkysightStartRequest",
  pause: "ComputerUseIPCSkysightPauseRequest",
  resume: "ComputerUseIPCSkysightResumeRequest",
  stop: "ComputerUseIPCSkysightStopRequest",
  clearInterval: "ComputerUseIPCSkysightClearHistoryRequest",
};
const command = process.argv[2] ?? "snapshot";
const writeCommands = new Set([
  "start",
  "pause",
  "resume",
  "stop",
  "clear-interval",
]);
if (
  ![
    "ping",
    "status",
    "settings",
    "event-stream-status",
    "snapshot",
    ...writeCommands,
  ].includes(command)
) {
  console.error(
    "Usage: original-ipc.mjs ping|status|settings|event-stream-status|snapshot|start|pause|resume|stop|clear-interval <start> <end> [--allow-write]",
  );
  process.exit(2);
}
if (writeCommands.has(command) && !process.argv.includes("--allow-write")) {
  console.error("Write commands require --allow-write.");
  process.exit(2);
}

async function serviceRequest(transport, requestType, request = {}) {
  return transport.call("request", {
    clientApiVersion: apiVersion,
    codexTurnMetadata: null,
    deadlineUnixMilliseconds: Date.now() + 10_000,
    request,
    requestType,
  });
}

function print(value) {
  console.log(JSON.stringify(value, null, 2));
}

class NativePipeTransport {
  static async connect(path) {
    let lastError;
    for (let attempt = 1; attempt <= 50; attempt += 1) {
      let transport;
      try {
        transport = await NativePipeTransport.open(path, 1_000);
        await transport.call("ping", { clientApiVersion: apiVersion }, 1_500);
        return transport;
      } catch (error) {
        lastError = error;
        transport?.close();
        await delay(Math.min(500, attempt * 25));
      }
    }
    throw new Error(`Could not establish Computer History IPC: ${lastError}`);
  }

  static async open(path, timeoutMilliseconds) {
    return await new Promise((resolve, reject) => {
      const socket = net.createConnection(path);
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error(`Connection timed out: ${path}`));
      }, timeoutMilliseconds);
      socket.once("connect", () => {
        clearTimeout(timer);
        resolve(new NativePipeTransport(socket));
      });
      socket.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  constructor(socket) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.nextID = 1;
    this.pending = new Map();
    socket.on("data", (chunk) => this.receive(chunk));
    socket.on("error", (error) => this.fail(error));
    socket.on("close", () => this.fail(new Error("IPC socket closed")));
  }

  call(method, params, timeoutMilliseconds = 10_000) {
    const id = this.nextID++;
    const body = Buffer.from(
      JSON.stringify({ id, jsonrpc: "2.0", method, params }),
      "utf8",
    );
    if (body.length > 8 * 1024 * 1024) {
      return Promise.reject(new Error("IPC frame exceeds 8 MiB"));
    }
    const frame = Buffer.alloc(4 + body.length);
    frame.writeUInt32LE(body.length, 0);
    body.copy(frame, 4);

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`IPC ${method} timed out`));
      }, timeoutMilliseconds);
      this.pending.set(id, { resolve, reject, timeout });
      this.socket.write(frame);
    });
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32LE(0);
      if (length > 8 * 1024 * 1024) {
        this.fail(new Error(`Invalid IPC frame length: ${length}`));
        return;
      }
      if (this.buffer.length < 4 + length) return;
      const message = JSON.parse(
        this.buffer.subarray(4, 4 + length).toString("utf8"),
      );
      this.buffer = this.buffer.subarray(4 + length);
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      this.pending.delete(message.id);
      clearTimeout(pending.timeout);
      if (message.error) {
        pending.reject(
          new Error(`IPC ${message.error.code}: ${message.error.message}`),
        );
      } else {
        pending.resolve(message.result);
      }
    }
  }

  fail(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
  }

  close() {
    this.socket.end();
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function main() {
  const transport = await NativePipeTransport.connect(socketPath);
  try {
    const ping = await transport.call("ping", { clientApiVersion: apiVersion });
    if (command === "ping") {
      print(ping);
    } else if (command === "status") {
      print(await serviceRequest(transport, requestTypes.status));
    } else if (command === "settings") {
      print(await serviceRequest(transport, requestTypes.settings));
    } else if (command === "event-stream-status") {
      print(await serviceRequest(transport, requestTypes.eventStreamStatus));
    } else if (command === "clear-interval") {
      const start = process.argv[3];
      const end = process.argv[4];
      if (!start || !end) {
        throw new Error("clear-interval requires start and end timestamps.");
      }
      print(
        await serviceRequest(transport, requestTypes.clearInterval, {
          scope: "interval",
          interval: {
            start: foundationReferenceSeconds(start),
            end: foundationReferenceSeconds(end),
          },
        }),
      );
    } else if (writeCommands.has(command)) {
      print(await serviceRequest(transport, requestTypes[command]));
    } else {
      print({
        ping,
        status: await serviceRequest(transport, requestTypes.status),
        settings: await serviceRequest(transport, requestTypes.settings),
        eventStreamStatus: await serviceRequest(
          transport,
          requestTypes.eventStreamStatus,
        ),
      });
    }
  } finally {
    transport.close();
  }
}

function foundationReferenceSeconds(value) {
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) {
    throw new Error(`Invalid timestamp: ${value}`);
  }
  return milliseconds / 1000 - 978307200;
}

await main();
