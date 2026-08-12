import { describe, expect, it } from "bun:test";
import { Store } from "./store";

describe("Store", () => {
  it("returns notes from the target dir", async () => {
    const s = new Store({ path: "./fixtures" });
    const notes = await s.list();
    expect(notes.length).toBeGreaterThan(0);
  });
});
