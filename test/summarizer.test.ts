import assert from "node:assert/strict";
import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { summarizeInterval } from "../src/summarizer.ts";

async function eventFixture() {
  const home = await mkdtemp(join(tmpdir(), "open-history-summary-test-"));
  process.env.OPEN_COMPUTER_HISTORY_HOME = home;
  const segment = join(home, "segments", "fixture");
  await mkdir(segment, { recursive: true });
  const start = new Date("2026-08-14T17:20:00Z");
  const end = new Date("2026-08-14T17:30:00Z");
  await writeFile(
    join(segment, "events.jsonl"),
    `${JSON.stringify({
      id: 1,
      timestamp: "2026-08-14T17:21:00Z",
      kind: "window.changed",
      app: {
        name: "Editor",
        secureInput: false,
        bundleIdentifier: "com.example.Editor",
      },
      window: { title: "Planning notes", windowID: 7 },
    })}\n`,
  );
  return { home, start, end };
}

test("summarizer writes a validated memory through the configured Codex binary", async () => {
  const { home, start, end } = await eventFixture();
  const fake = join(home, "fake-codex-success.sh");
  await writeFile(
    fake,
    `#!/bin/sh
out=""
previous=""
for arg in "$@"; do
  if [ "$previous" = "-o" ]; then out="$arg"; fi
  previous="$arg"
done
cat > "$out" <<'EOF'
---
title: Planning notes
description: You reviewed planning notes in an editor.
applications: [com.example.Editor]
---
## Memory summary
The user reviewed planning notes.
### Relevant prior context
No relevant prior context established.
### Important non-obvious context about the user
No additional context established.
## Recording summary
The editor window was active.
## Citations
- fixture/events.jsonl
EOF
`,
  );
  await chmod(fake, 0o755);
  process.env.OPEN_HISTORY_CODEX_BIN = fake;

  const result = await summarizeInterval({ start, end, level: "10min" });
  assert.equal(result.eventCount, 1);
  assert.match(await readFile(result.memoryPath, "utf8"), /Planning notes/u);
});

test("summarizer circuit prevents immediate retry storms", async () => {
  const { home, start, end } = await eventFixture();
  const countPath = join(home, "invocations.txt");
  const fake = join(home, "fake-codex-failure.sh");
  await writeFile(
    fake,
    `#!/bin/sh
echo called >> "${countPath}"
echo backend-unavailable >&2
exit 1
`,
  );
  await chmod(fake, 0o755);
  process.env.OPEN_HISTORY_CODEX_BIN = fake;

  await assert.rejects(
    summarizeInterval({ start, end, level: "10min" }),
    /backend-unavailable/u,
  );
  await assert.rejects(
    summarizeInterval({ start, end, level: "10min" }),
    /circuit is open/u,
  );
  const invocations = (await readFile(countPath, "utf8")).trim().split(/\n/u);
  assert.equal(invocations.length, 1);
});
