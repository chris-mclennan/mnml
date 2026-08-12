import type { Store } from "./store";

export class Server {
  constructor(private opts: { store: Store; port: number }) {}
  get port() { return this.opts.port; }

  async listen(): Promise<void> {
    // TODO: middleware pipeline (NTL-142)
    Bun.serve({
      port: this.port,
      fetch: (req) => this.handle(req),
    });
  }

  private async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/notes" && req.method === "GET") {
      return Response.json(await this.opts.store.list());
    }
    return new Response("not found", { status: 404 });
  }
}
