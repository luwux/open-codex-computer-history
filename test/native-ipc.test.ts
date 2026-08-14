import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { dispatchNativeRequest } from "../src/native-ipc-server.ts";

test("native IPC ping and read-only requests match recovered protocol", async () => {
  process.env.OPEN_COMPUTER_HISTORY_HOME = await mkdtemp(
    join(tmpdir(), "open-history-ipc-test-"),
  );
  const common = { clientApiVersion: "CodexComputerUseIPC-2" };
  assert.deepEqual(await dispatchNativeRequest("ping", common), {
    serverApiVersion: "CodexComputerUseIPC-2",
  });
  const status = (await dispatchNativeRequest("request", {
    ...common,
    requestType: "ComputerUseIPCSkysightStatusRequest",
    request: {},
  })) as { state: string };
  assert.equal(status.state, "stopped");

  const settings = (await dispatchNativeRequest("request", {
    ...common,
    requestType: "ComputerUseIPCSkysightGetSettingsRequest",
    request: {},
  })) as { observation: { defaultApplicationBehavior: string } };
  assert.equal(settings.observation.defaultApplicationBehavior, "observe");

  const stream = (await dispatchNativeRequest("request", {
    ...common,
    requestType: "ComputerUseIPCEventStreamStatusRequest",
    request: {},
  })) as { isRecording: boolean; maxDurationSeconds: number };
  assert.equal(stream.isRecording, false);
  assert.equal(stream.maxDurationSeconds, 1800);
});

test("native IPC rejects incompatible versions", async () => {
  await assert.rejects(
    dispatchNativeRequest("ping", { clientApiVersion: "wrong" }),
    /version mismatch/u,
  );
});
