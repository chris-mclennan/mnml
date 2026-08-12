import { Server } from "./server";
import { Store } from "./store";

const store = new Store({ path: process.env.NTL_STORE ?? "./data" });
const server = new Server({ store, port: 7070 });

await server.listen();
console.log(`notely-api on :${server.port}`);
