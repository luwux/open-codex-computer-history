import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

async function fixture() {
  const home = await mkdtemp(join(tmpdir(), "open-history-test-"));
  process.env.OPEN_COMPUTER_HISTORY_HOME = home;
  const segment = join(home, "segments", "fixture");
  await mkdir(segment, { recursive: true });
  const now = new Date().toISOString();
  await writeFile(
    join(segment, "events.jsonl"),
    [
      JSON.stringify({
        timestamp: now,
        kind: "window.changed",
        app: { bundleIdentifier: "com.example.Editor" },
        window: { title: "Launch plan" },
        keyboard: { text: "sensitive text" },
        ax: { mode: "fullTree", text: "sensitive tree" },
      }),
      JSON.stringify({
        timestamp: now,
        kind: "mouse.click",
        app: { bundleIdentifier: "com.example.Editor" },
      }),
    ].join("\n") + "\n",
  );
  return home;
}

test("recent events redact content by default", async () => {
  await fixture();
  const { readRecentEvents } = await import("../src/history-store.ts");
  const events = await readRecentEvents({
    hours: 1,
    limit: 10,
    includeText: false,
  });
  assert.equal(events.length, 2);
  assert.equal(events[0]!.keyboard?.text, undefined);
  assert.equal("ax" in events[0]!, false);
});

test("search finds window titles but keeps captured text redacted", async () => {
  await fixture();
  const { searchHistory } = await import("../src/history-store.ts");
  const result = await searchHistory({
    query: "Launch plan",
    hours: 1,
    limit: 10,
    includeText: false,
  });
  assert.equal(result.eventMatches.length, 1);
  assert.equal(result.eventMatches[0]!.keyboard?.text, undefined);
});

test("application-session clearing removes only the latest contiguous app session", async () => {
  const home = await mkdtemp(join(tmpdir(), "open-history-session-test-"));
  process.env.OPEN_COMPUTER_HISTORY_HOME = home;
  const segment = join(home, "segments", "fixture");
  await mkdir(segment, { recursive: true });
  const now = Date.now();
  const event = (
    id: number,
    ageSeconds: number,
    bundleIdentifier: string,
  ) => ({
    id,
    timestamp: new Date(now - ageSeconds * 1000).toISOString(),
    kind: "window.changed",
    app: { bundleIdentifier, secureInput: false },
  });
  await writeFile(
    join(segment, "events.jsonl"),
    [
      event(1, 40, "com.example.Editor"),
      event(2, 30, "com.example.Browser"),
      event(3, 20, "com.example.Editor"),
      event(4, 10, "com.example.Editor"),
    ]
      .map(JSON.stringify)
      .join("\n") + "\n",
  );
  await writeFile(join(segment, "suppressed.jsonl"), "");

  const { clearHistoryRequest } = await import("../src/history-store.ts");
  const result = await clearHistoryRequest({
    scope: "application_session",
    bundleIdentifier: "com.example.Editor",
  });
  assert.equal(result.deletedEventCount, 2);
  const remaining = await readFile(join(segment, "events.jsonl"), "utf8");
  assert.match(remaining, /"id":1/u);
  assert.match(remaining, /"id":2/u);
  assert.doesNotMatch(remaining, /"id":3/u);
  assert.doesNotMatch(remaining, /"id":4/u);
});
