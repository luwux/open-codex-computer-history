import assert from "node:assert/strict";
import { mkdtemp, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  type ComputerHistorySettings,
  getComputerHistorySettings,
  updateComputerHistorySettings,
} from "../src/settings.ts";

async function useTemporaryHome(): Promise<string> {
  const home = await mkdtemp(join(tmpdir(), "open-history-settings-test-"));
  process.env.OPEN_COMPUTER_HISTORY_HOME = home;
  return home;
}

async function readConfig(home: string): Promise<Record<string, unknown>> {
  return JSON.parse(await readFile(join(home, "config.json"), "utf8"));
}

const updated: ComputerHistorySettings = {
  observation: {
    defaultApplicationBehavior: "do_not_observe",
    defaultURLBehavior: "observe",
    allowlist: [{ scope: "application", bundleID: "com.apple.Safari" }],
    blocklist: [{ scope: "url", urlDomain: "bank.example" }],
  },
  showMenuBarIcon: false,
};

test("update preserves recorder-owned and unknown keys", async () => {
  const home = await useTemporaryHome();
  const recorderKeys = {
    captureText: false,
    axCapture: { maxDepth: 12 },
    webAccessibility: { mode: "manual", bundleIdentifiers: ["com.google.Chrome"] },
    browserScripting: { enabled: true },
    pageText: { source: "cdp", port: 9222, bundleIdentifiers: [] },
    someFutureKey: { nested: [1, 2, 3] },
  };
  await writeFile(
    join(home, "config.json"),
    JSON.stringify({
      observation: {
        defaultApplicationBehavior: "observe",
        defaultURLBehavior: "observe",
        allowlist: [],
        blocklist: [],
      },
      showMenuBarIcon: true,
      ...recorderKeys,
    }),
  );

  assert.deepEqual(await updateComputerHistorySettings(updated), updated);

  const config = await readConfig(home);
  assert.deepEqual(config, { ...updated, ...recorderKeys });
  assert.deepEqual(await getComputerHistorySettings(), updated);
  assert.deepEqual(await readdir(home), ["config.json"]);
});

test("update replaces owned keys completely", async () => {
  const home = await useTemporaryHome();
  await updateComputerHistorySettings(updated);
  const replacement: ComputerHistorySettings = {
    observation: {
      defaultApplicationBehavior: "observe",
      defaultURLBehavior: "do_not_observe",
      allowlist: [],
      blocklist: [],
    },
    showMenuBarIcon: true,
  };
  await updateComputerHistorySettings(replacement);
  assert.deepEqual(await readConfig(home), replacement);
});

test("update creates config when the file is missing", async () => {
  const home = await useTemporaryHome();
  assert.equal((await getComputerHistorySettings()).showMenuBarIcon, true);
  await updateComputerHistorySettings(updated);
  assert.deepEqual(await readConfig(home), updated);
});

test("update refuses to overwrite a config it cannot parse", async () => {
  const home = await useTemporaryHome();
  await writeFile(join(home, "config.json"), "{ not json");
  await assert.rejects(updateComputerHistorySettings(updated));
  assert.equal(await readFile(join(home, "config.json"), "utf8"), "{ not json");
});

test("get falls back per key like the Swift recorder", async () => {
  const home = await useTemporaryHome();
  await writeFile(
    join(home, "config.json"),
    JSON.stringify({ observation: updated.observation, captureText: false }),
  );
  assert.deepEqual(await getComputerHistorySettings(), {
    observation: updated.observation,
    showMenuBarIcon: true,
  });
});

test("concurrent updates keep unknown keys and apply the last write", async () => {
  const home = await useTemporaryHome();
  await writeFile(join(home, "config.json"), JSON.stringify({ captureText: false }));
  await Promise.all([
    updateComputerHistorySettings({ ...updated, showMenuBarIcon: true }),
    updateComputerHistorySettings(updated),
  ]);
  assert.deepEqual(await readConfig(home), { captureText: false, ...updated });
});
