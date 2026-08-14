import { runPipelineLoop, runPipelineTick } from "../src/pipeline.js";

const command = process.argv[2] ?? "once";
if (command === "once") {
  console.log(JSON.stringify(await runPipelineTick(), null, 2));
} else if (command === "run") {
  await runPipelineLoop();
} else {
  console.error("Usage: pipeline.ts once|run");
  process.exit(2);
}
