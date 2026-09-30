import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { z } from "zod";
import { historyHome } from "./history-store.js";

export const behaviorSchema = z.enum(["observe", "do_not_observe"]);
export const observationRuleSchema = z.object({
  scope: z.enum(["application", "url"]),
  bundleID: z.string().min(1).optional(),
  urlDomain: z.string().min(1).optional(),
});
export const observationSettingsSchema = z.object({
  defaultApplicationBehavior: behaviorSchema,
  defaultURLBehavior: behaviorSchema,
  allowlist: z.array(observationRuleSchema),
  blocklist: z.array(observationRuleSchema),
});
export const computerHistorySettingsSchema = z.object({
  observation: observationSettingsSchema,
  showMenuBarIcon: z.boolean(),
});

export type ComputerHistorySettings = z.infer<
  typeof computerHistorySettingsSchema
>;

const defaultSettings: ComputerHistorySettings = {
  observation: {
    defaultApplicationBehavior: "observe",
    defaultURLBehavior: "observe",
    allowlist: [],
    blocklist: [],
  },
  showMenuBarIcon: true,
};

/**
 * Keys in `config.json` owned by the settings tools. Every other key
 * (`captureText`, `axCapture`, `webAccessibility`, `browserScripting`,
 * `pageText`, and any future recorder keys) belongs to the Swift recorder and
 * must survive a settings update untouched.
 */
const ownedKeys = ["observation", "showMenuBarIcon"] as const;

function configPath(): string {
  return join(historyHome(), "config.json");
}

/**
 * Reads the whole config object. Returns `undefined` when the file does not
 * exist; throws when it exists but is not a JSON object, so callers never
 * overwrite a file they could not understand.
 */
async function readConfigObject(): Promise<Record<string, unknown> | undefined> {
  let text: string;
  try {
    text = await readFile(configPath(), "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return undefined;
    }
    throw error;
  }
  const raw: unknown = JSON.parse(text);
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new Error(`${configPath()} does not contain a JSON object.`);
  }
  return raw as Record<string, unknown>;
}

/**
 * Mirrors the Swift recorder's decoding: each owned key falls back to its own
 * default when missing or invalid, instead of discarding the whole file.
 */
function ownedSettingsFrom(
  raw: Record<string, unknown> | undefined,
): ComputerHistorySettings {
  const observation = observationSettingsSchema.safeParse(raw?.observation);
  const showMenuBarIcon = z.boolean().safeParse(raw?.showMenuBarIcon);
  return {
    observation: observation.success
      ? observation.data
      : structuredClone(defaultSettings.observation),
    showMenuBarIcon: showMenuBarIcon.success
      ? showMenuBarIcon.data
      : defaultSettings.showMenuBarIcon,
  };
}

export async function getComputerHistorySettings(): Promise<ComputerHistorySettings> {
  try {
    return ownedSettingsFrom(await readConfigObject());
  } catch {
    return structuredClone(defaultSettings);
  }
}

let updateQueue: Promise<unknown> = Promise.resolve();

/**
 * Replaces the complete tool-owned settings object (`observation` and
 * `showMenuBarIcon`) while preserving every other key in `config.json`.
 * Updates within this process are serialized, and the file is replaced
 * atomically via a temporary file and rename.
 */
export async function updateComputerHistorySettings(
  settings: ComputerHistorySettings,
): Promise<ComputerHistorySettings> {
  validateRules(settings);
  const parsed = computerHistorySettingsSchema.parse(settings);
  const run = updateQueue.then(() => writeOwnedSettings(parsed));
  updateQueue = run.catch(() => undefined);
  return run;
}

async function writeOwnedSettings(
  parsed: ComputerHistorySettings,
): Promise<ComputerHistorySettings> {
  const path = configPath();
  const existing = (await readConfigObject()) ?? {};
  const next: Record<string, unknown> = { ...existing };
  for (const key of ownedKeys) {
    next[key] = parsed[key];
  }
  const temporaryPath = `${path}.tmp-${process.pid}-${randomUUID()}`;
  await mkdir(dirname(path), { recursive: true });
  try {
    await writeFile(temporaryPath, `${JSON.stringify(next, null, 2)}\n`, {
      mode: 0o600,
    });
    await rename(temporaryPath, path);
  } catch (error) {
    await rm(temporaryPath, { force: true });
    throw error;
  }
  return parsed;
}

function validateRules(settings: ComputerHistorySettings): void {
  for (const rule of [
    ...settings.observation.allowlist,
    ...settings.observation.blocklist,
  ]) {
    if (rule.scope === "application" && !rule.bundleID) {
      throw new Error("Application observation rules require bundleID.");
    }
    if (rule.scope === "url" && !rule.urlDomain) {
      throw new Error("URL observation rules require urlDomain.");
    }
    if (rule.scope === "application" && rule.urlDomain) {
      throw new Error("Application observation rules cannot include urlDomain.");
    }
    if (rule.scope === "url" && rule.bundleID) {
      throw new Error("URL observation rules cannot include bundleID.");
    }
  }
}
