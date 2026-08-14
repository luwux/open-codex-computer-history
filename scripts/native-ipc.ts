import { startNativeIPCServer } from "../src/native-ipc-server.js";

const server = await startNativeIPCServer();
console.log("Open Computer History native IPC server is running.");

const shutdown = () => {
  server.close(() => process.exit(0));
};
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
