import assert from "node:assert/strict";
import test from "node:test";
import { previousCompletedBucket } from "../src/pipeline.ts";

test("10-minute buckets align to UTC boundaries", () => {
  const bucket = previousCompletedBucket(
    new Date("2026-08-14T17:37:42Z"),
    10 * 60 * 1000,
  );
  assert.equal(bucket.start.toISOString(), "2026-08-14T17:20:00.000Z");
  assert.equal(bucket.end.toISOString(), "2026-08-14T17:30:00.000Z");
});

test("6-hour buckets align to UTC boundaries", () => {
  const bucket = previousCompletedBucket(
    new Date("2026-08-14T17:37:42Z"),
    6 * 60 * 60 * 1000,
  );
  assert.equal(bucket.start.toISOString(), "2026-08-14T06:00:00.000Z");
  assert.equal(bucket.end.toISOString(), "2026-08-14T12:00:00.000Z");
});
