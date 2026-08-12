import { Server } from "./server";
import { Store } from "./store";

const store = new Store({ path: process.env.LOOP_STORE ?? "./data" });
const server = new Server({ store, port: 7070 });

await server.listen();
console.log(`loop-api on :${server.port}`);
