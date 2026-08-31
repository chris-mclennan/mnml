import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

export interface Note {
  id: string;
  title: string;
  updated: number;
}

export class Store {
  constructor(private opts: { path: string }) {}

  async list(): Promise<Note[]> {
    const files = await readdir(this.opts.path);
    return Promise.all(
      files
        .filter((f) => f.endsWith(".md"))
        .map(async (name) => this.load(join(this.opts.path, name))),
    );
  }

  private async load(path: string): Promise<Note> {
    const body = await readFile(path, "utf8");
    const title = body.split("\n")[0]?.replace(/^#\s*/, "") ?? path;
    return { id: path, title, updated: Date.now() };
  }
}
export function reset(state: Store): Store {
  return { ...state, items: [] };
}
