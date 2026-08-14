import { MCPServer } from "mcp-use";
import { z } from "zod";
import {
  clearHistory,
  getHistoryStatus,
  readRecentEvents,
  searchHistory,
} from "./src/history-store.js";
import { summarizeRecentHistory } from "./src/summarizer.js";
import {
  computerHistorySettingsSchema,
  getComputerHistorySettings,
  updateComputerHistorySettings,
} from "./src/settings.js";
import {
  pauseRecorder,
  recorderStatus,
  resumeRecorder,
} from "./src/runtime-control.js";
import {
  deleteTimelineItem,
  loadTimeline,
} from "./src/timeline.js";

const server = new MCPServer({
  name: "open-codex-computer-history",
  title: "Open Codex Computer History",
  version: "0.1.0",
  description:
    "Query and summarize a local macOS interaction-event stream without screenshots.",
});

const eventSchema = z.record(z.string(), z.unknown());
const runtimeStatusSchema = z.object({
  state: z.enum(["stopped", "running", "paused"]),
  processIdentifier: z.number().optional(),
  eventStreamRootPath: z.string(),
  currentSegmentEventsPath: z.string().optional(),
  currentSegmentMetadataPath: z.string().optional(),
  suppressedEventsPath: z.string().optional(),
  startedAt: z.string().optional(),
  endedAt: z.string().optional(),
});
const timelineEntrySchema = z.object({
  id: z.string(),
  title: z.string(),
  description: z.string(),
  applications: z.array(z.string()),
  start: z.string(),
  end: z.string(),
  level: z.enum(["10min", "6h"]),
  suggestion: z
    .object({
      type: z.enum(["skill", "automation"]),
      name: z.string(),
      description: z.string(),
    })
    .optional(),
});

export const showComputerHistory = server.tool(
  {
    name: "show-computer-history",
    title: "Computer History",
    description:
      "Show the local Computer History timeline, recording status, contributing apps, and workflow suggestions.",
    inputSchema: z.object({
      days: z
        .number()
        .int()
        .min(1)
        .max(30)
        .default(7)
        .describe("Number of recent days to show"),
    }),
    outputSchema: z.object({
      status: runtimeStatusSchema,
      entryCount: z.number(),
      entries: z.array(timelineEntrySchema),
    }),
    view: {
      name: "computer-history",
      description:
        "A chronological local Computer History timeline with status and workflow suggestions.",
      prefersBorder: false,
      csp: {},
    },
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async ({ days }) => {
    try {
      return resultEnvelope(await loadTimeline(days));
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const deleteComputerHistoryItem = server.tool(
  {
    name: "delete-computer-history-item",
    description:
      "Permanently delete one local Computer History timeline item and its matching event interval.",
    inputSchema: z.object({
      id: z.string().describe("Timeline item id returned by show-computer-history"),
    }),
    outputSchema: z.object({
      deleted: z.boolean(),
      id: z.string(),
    }),
    visibility: "app",
    annotations: {
      readOnlyHint: false,
      openWorldHint: false,
      destructiveHint: true,
    },
  },
  async ({ id }) => {
    try {
      return resultEnvelope(await deleteTimelineItem(id));
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const originalComputerHistoryPause = server.tool(
  {
    name: "computer_history_pause",
    description: "Temporarily pause Computer History without disabling it.",
    inputSchema: z.object({}),
    outputSchema: runtimeStatusSchema,
    annotations: {
      readOnlyHint: false,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async () => {
    try {
      return resultEnvelope(await pauseRecorder());
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const originalComputerHistoryResume = server.tool(
  {
    name: "computer_history_resume",
    description: "Resume a paused Computer History recorder.",
    inputSchema: z.object({}),
    outputSchema: runtimeStatusSchema,
    annotations: {
      readOnlyHint: false,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async () => {
    try {
      return resultEnvelope(await resumeRecorder());
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const originalComputerHistoryStatus = server.tool(
  {
    name: "computer_history_status",
    description:
      "Get Computer History status and paths to recent activity files.",
    inputSchema: z.object({}),
    outputSchema: runtimeStatusSchema,
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async () => {
    try {
      return resultEnvelope(await recorderStatus());
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const originalComputerHistoryGetSettings = server.tool(
  {
    name: "computer_history_get_settings",
    description:
      "Get all Computer History settings. Call this immediately before updating settings so unchanged fields can be preserved.",
    inputSchema: z.object({}),
    outputSchema: computerHistorySettingsSchema,
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async () => {
    try {
      return resultEnvelope(await getComputerHistorySettings());
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const originalComputerHistoryUpdateSettings = server.tool(
  {
    name: "computer_history_update_settings",
    description:
      "Replace all Computer History settings. Preserve every setting the user did not ask to change by first calling computer_history_get_settings.",
    inputSchema: z.object({ settings: computerHistorySettingsSchema }),
    outputSchema: computerHistorySettingsSchema,
    annotations: {
      readOnlyHint: false,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async ({ settings }) => {
    try {
      return resultEnvelope(await updateComputerHistorySettings(settings));
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const computerHistoryStatus = server.tool(
  {
    name: "computer-history-status",
    description:
      "Inspect the local Computer History store, retention state, event counts, and memory counts.",
    inputSchema: z.object({}),
    outputSchema: z.object({
      home: z.string(),
      segmentCount: z.number(),
      eventCount: z.number(),
      suppressedEventCount: z.number(),
      memoryCount: z.number(),
      newestEventAt: z.string().nullable(),
    }),
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async () => {
    try {
      const result = await getHistoryStatus();
      return resultEnvelope(result);
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const getRecentComputerHistory = server.tool(
  {
    name: "get-recent-computer-history",
    description:
      "Read recent local interaction events, filtered by time, event type, or application. Text and accessibility-tree content are redacted unless explicitly requested.",
    inputSchema: z.object({
      hours: z.number().positive().max(48).default(2).describe("Lookback window in hours"),
      limit: z.number().int().positive().max(500).default(100).describe("Maximum events"),
      eventTypes: z
        .array(z.string())
        .optional()
        .describe("Optional event types such as window.changed or mouse.click"),
      applications: z
        .array(z.string())
        .optional()
        .describe("Optional application bundle identifiers"),
      includeText: z
        .boolean()
        .default(false)
        .describe("Include captured text and AX tree fields"),
    }),
    outputSchema: z.object({
      count: z.number(),
      events: z.array(eventSchema),
    }),
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async (input) => {
    try {
      const events = await readRecentEvents(input);
      return resultEnvelope({ count: events.length, events });
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const searchComputerHistory = server.tool(
  {
    name: "search-computer-history",
    description:
      "Search local Computer History events and generated Markdown memories for an app, task, window, file, or keyword.",
    inputSchema: z.object({
      query: z.string().min(2).max(200).describe("Case-insensitive search query"),
      hours: z.number().positive().max(48).default(24).describe("Event lookback window"),
      limit: z.number().int().positive().max(100).default(30).describe("Maximum matches"),
      includeText: z
        .boolean()
        .default(false)
        .describe("Include captured text and AX tree fields in event matches"),
    }),
    outputSchema: z.object({
      eventMatches: z.array(eventSchema),
      memoryMatches: z.array(
        z.object({
          path: z.string(),
          title: z.string(),
          excerpt: z.string(),
        }),
      ),
    }),
    annotations: {
      readOnlyHint: true,
      openWorldHint: false,
      destructiveHint: false,
    },
  },
  async (input) => {
    try {
      return resultEnvelope(await searchHistory(input));
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const summarizeComputerHistory = server.tool(
  {
    name: "summarize-computer-history",
    description:
      "Run an ephemeral Codex session over recent local events and save a Computer History-style Markdown memory.",
    inputSchema: z.object({
      minutes: z
        .number()
        .int()
        .min(1)
        .max(360)
        .default(10)
        .describe("Recent activity window to summarize"),
    }),
    outputSchema: z.object({
      memoryPath: z.string(),
      eventCount: z.number(),
      summary: z.string(),
    }),
    annotations: {
      readOnlyHint: false,
      openWorldHint: true,
      destructiveHint: false,
    },
  },
  async ({ minutes }) => {
    try {
      return resultEnvelope(await summarizeRecentHistory({ minutes }));
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

export const clearComputerHistory = server.tool(
  {
    name: "clear-computer-history",
    description:
      "Delete local event records and generated memories for a selected time scope.",
    inputSchema: z.object({
      scope: z
        .enum(["last_10_minutes", "last_hour", "last_day", "all"])
        .describe("History interval to permanently delete"),
    }),
    outputSchema: z.object({
      deletedEventCount: z.number(),
      deletedMemoryCount: z.number(),
    }),
    annotations: {
      readOnlyHint: false,
      openWorldHint: false,
      destructiveHint: true,
    },
  },
  async ({ scope }) => {
    try {
      return resultEnvelope(await clearHistory(scope));
    } catch (error) {
      return errorEnvelope(error);
    }
  },
);

function resultEnvelope<T>(value: T): {
  content: { type: "text"; text: string }[];
  structuredContent: T;
} {
  return {
    content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }],
    structuredContent: value,
  };
}

function errorEnvelope(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  return {
    isError: true as const,
    content: [{ type: "text" as const, text: message }],
  };
}

export default server;
