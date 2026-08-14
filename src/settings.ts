import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
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

export async function getComputerHistorySettings(): Promise<ComputerHistorySettings> {
  try {
    const raw: unknown = JSON.parse(
      await readFile(join(historyHome(), "config.json"), "utf8"),
    );
    return computerHistorySettingsSchema.parse(raw);
  } catch {
    return structuredClone(defaultSettings);
  }
}

export async function updateComputerHistorySettings(
  settings: ComputerHistorySettings,
): Promise<ComputerHistorySettings> {
  validateRules(settings);
  const parsed = computerHistorySettingsSchema.parse(settings);
  const configPath = join(historyHome(), "config.json");
  const temporaryPath = `${configPath}.tmp-${process.pid}`;
  await mkdir(dirname(configPath), { recursive: true });
  await writeFile(temporaryPath, `${JSON.stringify(parsed, null, 2)}\n`, {
    mode: 0o600,
  });
  await rename(temporaryPath, configPath);
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
