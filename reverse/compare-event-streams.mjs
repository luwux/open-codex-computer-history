#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const [originalEvents, originalSuppressed, openEvents, openSuppressed] =
  process.argv.slice(2);
if (!openSuppressed) {
  console.error(
    "Usage: compare-event-streams.mjs original-events original-suppressed open-events open-suppressed",
  );
  process.exit(2);
}

const original = {
  events: await fixtureRecords(originalEvents),
  suppressed: await fixtureRecords(originalSuppressed),
};
const open = {
  events: await fixtureRecords(openEvents),
  suppressed: await fixtureRecords(openSuppressed),
};

const comparison = {
  original: summarize(original),
  open: summarize(open),
  differences: compare(original, open),
};
console.log(JSON.stringify(comparison, null, 2));
if (comparison.differences.length) process.exitCode = 1;

async function fixtureRecords(path) {
  const text = await readFile(path, "utf8");
  return text
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter(
      (event) =>
        event.app?.bundleIdentifier === "dev.opencomputerhistory.fixture",
    );
}

function summarize(stream) {
  return {
    events: stream.events.map(signature),
    suppressed: stream.suppressed.map(signature),
  };
}

function signature(event) {
  return {
    kind: event.kind,
    topLevelFields: Object.keys(event)
      .filter((key) => !["id", "timestamp"].includes(key))
      .sort(),
    appFields: Object.keys(event.app ?? {}).sort(),
    windowFields: Object.keys(event.window ?? {}).sort(),
    mouseFields: Object.keys(event.mouse ?? {}).sort(),
    keyboardFields: Object.keys(event.keyboard ?? {}).sort(),
    selectionFields: Object.keys(event.selection ?? {}).sort(),
    axMode: event.ax?.mode ?? null,
    secureInput: event.app?.secureInput ?? null,
    stableValues: stableValues(event),
  };
}

function compare(originalStream, openStream) {
  const differences = [];
  for (const channel of ["events", "suppressed"]) {
    const originalSignatures = originalStream[channel].map(signature);
    const openSignatures = openStream[channel].map(signature);
    const originalKinds = counts(originalSignatures.map((item) => item.kind));
    const openKinds = counts(openSignatures.map((item) => item.kind));
    if (JSON.stringify(originalKinds) !== JSON.stringify(openKinds)) {
      differences.push({
        channel,
        issue: "event-kind counts differ",
        original: originalKinds,
        open: openKinds,
      });
    }

    const allKinds = new Set([
      ...originalSignatures.map((item) => item.kind),
      ...openSignatures.map((item) => item.kind),
    ]);
    for (const kind of allKinds) {
      const originalFields = fieldUnion(
        originalSignatures.filter((item) => item.kind === kind),
      );
      const openFields = fieldUnion(
        openSignatures.filter((item) => item.kind === kind),
      );
      if (JSON.stringify(originalFields) !== JSON.stringify(openFields)) {
        differences.push({
          channel,
          kind,
          issue: "field presence differs",
          original: originalFields,
          open: openFields,
        });
      }
      const originalValues = originalSignatures
        .filter((item) => item.kind === kind)
        .map((item) => item.stableValues);
      const openValues = openSignatures
        .filter((item) => item.kind === kind)
        .map((item) => item.stableValues);
      if (JSON.stringify(originalValues) !== JSON.stringify(openValues)) {
        differences.push({
          channel,
          kind,
          issue: "stable values differ",
          original: originalValues,
          open: openValues,
        });
      }
    }
  }
  return differences;
}

function stableValues(event) {
  return removeUndefined({
    app: event.app
      ? {
          bundleIdentifier: event.app.bundleIdentifier,
          name: event.app.name,
          secureInput: event.app.secureInput || undefined,
        }
      : undefined,
    window: event.window
      ? { title: event.window.title, url: event.window.url }
      : undefined,
    mouse: event.mouse
      ? {
          button: event.mouse.button,
          clickCount: event.mouse.clickCount,
          modifiers: event.mouse.modifiers,
          target: normalizeElement(event.mouse.target),
          origin: normalizeEndpoint(event.mouse.origin),
          destination: normalizeEndpoint(event.mouse.destination),
        }
      : undefined,
    keyboard: event.keyboard
      ? {
          text: event.keyboard.text,
          keyEquivalent: event.keyboard.keyEquivalent,
          modifiers: event.keyboard.modifiers,
          target: normalizeElement(event.keyboard.target),
        }
      : undefined,
    selection: event.selection
      ? {
          selectedText: event.selection.selectedText,
          selectedRange: event.selection.selectedRange,
          target: normalizeElement(event.selection.target),
          selectedItems: event.selection.selectedItems?.map(normalizeElement),
        }
      : undefined,
    ax: event.ax
      ? {
          mode: event.ax.mode,
          ...(event.ax.mode === "fullTree"
            ? { fixtureTokens: fixtureAXTokens(event.ax.text ?? "") }
            : {}),
        }
      : undefined,
  });
}

function normalizeEndpoint(endpoint) {
  if (!endpoint) return undefined;
  return removeUndefined({
    app: endpoint.app
      ? {
          bundleIdentifier: endpoint.app.bundleIdentifier,
          name: endpoint.app.name,
        }
      : undefined,
    window: endpoint.window ? { title: endpoint.window.title } : undefined,
    element: normalizeElement(endpoint.element),
  });
}

function normalizeElement(element) {
  if (!element) return undefined;
  return removeUndefined({
    role: element.role,
    subrole: element.subrole,
    title: element.title,
    description: element.description,
    value: element.value,
    placeholder: element.placeholder,
    identifier: element.identifier,
  });
}

function fixtureAXTokens(text) {
  const markers = [
    "synthetic-note",
    "synthetic-secret",
    "synthetic-action",
    "fixture-selection",
    "fixture-drop-target",
    "Synthetic payload",
    "Beta",
    "synthetic note",
  ];
  return markers.filter((marker) => text.includes(marker));
}

function removeUndefined(value) {
  if (Array.isArray(value)) {
    return value.map(removeUndefined);
  }
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value)
      .filter(([, item]) => item !== undefined)
      .map(([key, item]) => [key, removeUndefined(item)]),
  );
}

function counts(values) {
  return Object.fromEntries(
    [...new Set(values)]
      .sort()
      .map((value) => [value, values.filter((item) => item === value).length]),
  );
}

function fieldUnion(signatures) {
  const fields = new Set();
  for (const signature of signatures) {
    for (const [group, values] of Object.entries(signature)) {
      if (!Array.isArray(values)) continue;
      for (const value of values) fields.add(`${group}.${value}`);
    }
  }
  return [...fields].sort();
}
