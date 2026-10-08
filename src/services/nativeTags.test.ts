import { describe, expect, it, vi } from "vitest";
import { addNativeTags, normalizeNativeTags, type NativeTagSnapshot } from "./nativeTags.js";
import { classifyError } from "../utils/errorCodes.js";

const id = "x-coredata://ABCDEF/ICNote/p12";
const request = {
  id,
  expectedContentHash: "before",
  title: "Идеи",
  scopeText: "Project Shamaal",
  tags: ["shamaal", "дроп"],
};
const tagType = "com.apple.notes.inlinetextattachment.hashtag";
const styles = (text: string) => [{ start: 0, length: text.length, signature: "body" }];
const snapshot = (): NativeTagSnapshot => ({
  title: "Идеи",
  contentHash: "before",
  plaintext: "Идеи Project Shamaal #shamaal",
  rich: {
    text: "Идеи Project Shamaal #shamaal",
    links: [{ start: 0, length: 4, text: "Идеи", url: "notes://showNote?identifier=ABC" }],
    nativeTags: [],
    nativeObjectIds: [],
    hasNativeObjects: false,
    hasChecklist: false,
    revision: "r1",
    objects: [],
    objectData: [],
    checklistItems: [],
    nativeTagObjectIds: {},
    nativeObjectDataComplete: true,
    styleRuns: styles("Идеи Project Shamaal #shamaal"),
  },
});
function fixture() {
  const before = snapshot();
  const after = structuredClone(before);
  after.contentHash = "after";
  after.rich.nativeTags = ["shamaal", "дроп"];
  after.rich.text += "\n\ufffc \ufffc";
  after.rich.nativeObjectIds = ["a", "b"];
  after.rich.hasNativeObjects = true;
  after.rich.nativeTagObjectIds = { shamaal: ["a"], дроп: ["b"] };
  after.rich.styleRuns = styles(after.rich.text);
  after.rich.objects = ["a", "b"].map((id, i) => ({
    id,
    type: tagType,
    start: before.rich.text.length + 1 + i * 2,
    length: 1,
  }));
  after.rich.objectData = after.rich.objects.map(({ id, type }, i) => ({
    id,
    type,
    pk: i + 1,
    mergeable: "",
    view: null,
    altText: `#${request.tags[i]}`,
  }));
  const deps = {
    read: vi.fn().mockReturnValueOnce(before).mockReturnValueOnce(before).mockReturnValue(after),
    candidates: vi.fn(() => [id]),
    run: vi.fn(),
  };
  return { before, after, deps };
}
describe("native Notes tags", () => {
  it("normalizes Cyrillic and deduplicates tags without accepting commands or whitespace", () => {
    expect(normalizeNativeTags(["#дроп", "дроп", "project_1"])).toEqual(["дроп", "project_1"]);
    for (const tags of [[], ["$(cmd)"], ["a b"], ["123"], ["x\n"]])
      expect(() => normalizeNativeTags(tags)).toThrow();
  });
  it("verifies native tags, original text and real link destinations", () => {
    const { deps } = fixture();
    expect(addNativeTags(request, deps)).toMatchObject({
      added: ["shamaal", "дроп"],
      contentHash: "after",
    });
    expect(deps.run).toHaveBeenCalledWith({
      title: "Идеи",
      scopeText: "Project Shamaal",
      tags: ["shamaal", "дроп"],
    });
  });
  it("rejects stale revisions before invoking Shortcuts", () => {
    const { deps } = fixture();
    expect(() => addNativeTags({ ...request, expectedContentHash: "stale" }, deps)).toThrow(
      /revision/
    );
    expect(deps.run).not.toHaveBeenCalled();
  });
  it("rejects same-titled candidates in other projects and wrong exact IDs", () => {
    for (const candidates of [[id, "other"], ["other"], []]) {
      const { deps } = fixture();
      deps.candidates.mockReturnValue(candidates);
      expect(() => addNativeTags(request, deps)).toThrow(/ambiguous/);
      expect(deps.run).not.toHaveBeenCalled();
    }
  });
  it("rechecks the revision after resolving the target", () => {
    const { deps, before } = fixture();
    deps.read
      .mockReset()
      .mockReturnValueOnce(before)
      .mockReturnValue({ ...before, contentHash: "changed" });
    expect(() => addNativeTags(request, deps)).toThrow(/during preflight/);
    expect(deps.run).not.toHaveBeenCalled();
  });
  it("is idempotent when all native tags already exist", () => {
    const { deps, before } = fixture();
    before.rich.nativeTags = request.tags;
    expect(addNativeTags(request, deps).added).toEqual([]);
    expect(deps.run).not.toHaveBeenCalled();
  });
  it("does not mistake plain hashtags or a successful process for native tags", () => {
    const { deps, after } = fixture();
    after.rich.nativeTags = [];
    expect(() => addNativeTags(request, deps)).toThrow(/not verified/);
  });
  it("verifies an uncertain transport outcome without repeating the write", () => {
    const { deps } = fixture();
    deps.run.mockImplementation(() => {
      throw new Error("timeout");
    });
    expect(addNativeTags(request, deps)).toMatchObject({
      added: request.tags,
      transportWarning: expect.any(String),
    });
    expect(deps.run).toHaveBeenCalledTimes(1);
    const failed = fixture();
    failed.deps.run.mockImplementation(() => {
      throw new Error("timeout");
    });
    failed.after.rich.nativeTags = [];
    expect(() => addNativeTags(request, failed.deps)).toThrow(/not verified/);
  });
  // #172 item 5 — the transport diagnosis (which names the Shortcut and the
  // first-run consent fix) used to be swallowed when readback then failed.
  it("surfaces the transport diagnosis when readback fails after a stalled run", () => {
    const failed = fixture();
    failed.deps.run.mockImplementation(() => {
      throw new Error('run "Apple Notes MCP - Native Tags" once in the foreground');
    });
    failed.after.rich.nativeTags = [];
    // One invocation: the fixture's preflight reads are single-use.
    let message = "";
    try {
      addNativeTags(request, failed.deps);
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).toMatch(/did not complete cleanly.*not verified/);
    expect(message).toMatch(/run "Apple Notes MCP - Native Tags" once in the foreground/);
    const clean = fixture();
    clean.after.rich.nativeTags = [];
    expect(() => addNativeTags(request, clean.deps)).toThrow(/^Shortcuts ran, but/);
  });
  it("detects lost links, lost original objects and changed non-tag text", () => {
    const one = fixture();
    one.after.rich.links = [];
    const two = fixture();
    two.before.rich.nativeObjectIds = ["existing"];
    two.before.rich.hasNativeObjects = true;
    two.before.rich.objects = [{ id: "existing", type: "table", start: 0, length: 1 }];
    two.before.rich.objectData = [
      { id: "existing", type: "table", pk: 99, mergeable: "AA", view: 1, altText: null },
    ];
    const three = fixture();
    three.after.rich.text = "different text";
    for (const f of [one, two, three]) expect(() => addNativeTags(request, f.deps)).toThrow();
  });
  it.each([
    "Native metadata changed during read; read the note again",
    "Note not found",
    "Full Disk Access is unavailable",
    "Notes.app is not responding",
  ])("classifies a post-run read failure as indeterminate verification: %s", (message) => {
    const { before, deps } = fixture();
    deps.read
      .mockReset()
      .mockReturnValueOnce(before)
      .mockReturnValueOnce(before)
      .mockImplementation(() => {
        throw new Error(message);
      });
    let failure: unknown;
    try {
      addNativeTags(request, deps);
    } catch (error) {
      failure = error;
    }
    expect(classifyError((failure as Error).message, failure)).toEqual({
      code: "verification_failed",
      indeterminate: true,
    });
    expect((failure as Error).message).toContain(message);
    expect(deps.run).toHaveBeenCalledTimes(1);
    expect(deps.read).toHaveBeenCalledTimes(3);
  });
  it("retains the transport diagnosis when the post-run read itself fails", () => {
    const { before, deps } = fixture();
    deps.run.mockImplementation(() => {
      throw new Error("Native Tags Shortcut timed out");
    });
    deps.read
      .mockReset()
      .mockReturnValueOnce(before)
      .mockReturnValueOnce(before)
      .mockImplementation(() => {
        throw new Error("read failed");
      });
    try {
      addNativeTags(request, deps);
      expect.fail("Expected an indeterminate result");
    } catch (error) {
      expect((error as Error).message).toMatch(/read failed.*Native Tags Shortcut timed out/);
      expect(classifyError((error as Error).message, error).code).toBe("verification_failed");
    }
    expect(deps.run).toHaveBeenCalledTimes(1);
  });
  it("refuses missing project markers and malformed IDs", () => {
    for (const change of [
      { id: "title-only" },
      { scopeText: "missing project" },
      { scopeText: "tiny" },
      { title: "Other" },
    ]) {
      const { deps } = fixture();
      expect(() => addNativeTags({ ...request, ...change }, deps)).toThrow();
      expect(deps.run).not.toHaveBeenCalled();
    }
  });
});

/** Stored native content, including a hashtag converted before the retained ranges. */
function nativeFixture() {
  const { before, after, deps } = fixture();
  before.rich.text += "\n\ufffc\nChecklist item";
  before.rich.hasNativeObjects = true;
  before.rich.nativeObjectIds = ["table"];
  before.rich.objects = [
    {
      id: "table",
      type: "com.apple.notes.table",
      start: before.rich.text.indexOf("\ufffc"),
      length: 1,
    },
  ];
  before.rich.objectData = [
    {
      id: "table",
      type: "com.apple.notes.table",
      pk: 10,
      mergeable: "AABB",
      view: 1,
      altText: null,
    },
  ];
  before.rich.hasChecklist = true;
  before.rich.checklistItems = [
    {
      id: "item",
      text: "Checklist item",
      done: false,
      start: before.rich.text.indexOf("Checklist"),
    },
  ];
  before.rich.styleRuns = styles(before.rich.text);
  after.rich = structuredClone(before.rich);
  after.rich.text = before.rich.text.replace("#shamaal", "\ufffc") + "\n\ufffc";
  after.rich.nativeTags = [...request.tags];
  after.rich.nativeObjectIds = ["a", "table", "b"];
  after.rich.nativeTagObjectIds = { shamaal: ["a"], дроп: ["b"] };
  const shift = "#shamaal".length - 1;
  after.rich.objects = [
    { id: "a", type: tagType, start: after.rich.text.indexOf("\ufffc"), length: 1 },
    { ...before.rich.objects[0], start: before.rich.objects[0].start - shift },
    { id: "b", type: tagType, start: after.rich.text.length - 1, length: 1 },
  ];
  after.rich.objectData!.push(
    { id: "a", type: tagType, pk: 11, mergeable: "", view: null, altText: "#shamaal" },
    { id: "b", type: tagType, pk: 12, mergeable: "", view: null, altText: "#дроп" }
  );
  after.rich.checklistItems![0].start -= shift;
  after.rich.styleRuns = styles(after.rich.text);
  return { before, after, deps };
}

/** Keep readback ranges internally consistent so the body comparison has to catch a deletion. */
function replaceText(
  snapshot: NativeTagSnapshot,
  start: number,
  length: number,
  replacement: string
) {
  const rich = snapshot.rich;
  const end = start + length;
  const shift = replacement.length - length;
  rich.text = rich.text.slice(0, start) + replacement + rich.text.slice(end);
  for (const object of rich.objects!) if (object.start >= end) object.start += shift;
  for (const item of rich.checklistItems!) if (item.start >= end) item.start += shift;
  for (const link of rich.links) if (link.start >= end) link.start += shift;
  rich.styleRuns = styles(rich.text);
}

function existingTagFixture() {
  const f = nativeFixture();
  for (const note of [f.before, f.after]) {
    note.rich.nativeTags.push("existing");
    note.rich.nativeTagObjectIds!.existing = ["table"];
    note.rich.objects!.find((o) => o.id === "table")!.type = tagType;
    Object.assign(
      note.rich.objectData!.find((o) => o.id === "table")!,
      {
        type: tagType,
        altText: "#existing",
      }
    );
  }
  return f;
}

describe("native tag preservation", () => {
  it("accepts retained object payloads and checklist state after tag conversion shifts ranges", () => {
    const { deps } = nativeFixture();
    expect(addNativeTags(request, deps).added).toEqual(request.tags);
    expect(deps.run).toHaveBeenCalledTimes(1);
  });
  it("accepts a tag stored as its exact hashtag text instead of a placeholder", () => {
    const f = nativeFixture();
    const object = f.after.rich.objects![0];
    replaceText(f.after, object.start, 1, "#shamaal");
    object.length = 8;
    expect(addNativeTags(request, f.deps).added).toEqual(request.tags);
  });

  it.each([
    ["object payload", (r: NativeTagSnapshot) => (r.rich.objectData![0].mergeable = "CC")],
    ["object presentation", (r: NativeTagSnapshot) => (r.rich.objectData![0].view = 2)],
    ["object row", (r: NativeTagSnapshot) => (r.rich.objectData![0].pk = 50)],
    ["object type", (r: NativeTagSnapshot) => (r.rich.objects![1].type = "drawing")],
    ["object range", (r: NativeTagSnapshot) => (r.rich.objects![1].start = 0)],
    ["object length", (r: NativeTagSnapshot) => (r.rich.objects![1].length = 2)],
    ["checklist identity", (r: NativeTagSnapshot) => (r.rich.checklistItems![0].id = "new")],
    ["checklist state", (r: NativeTagSnapshot) => (r.rich.checklistItems![0].done = true)],
    ["checklist text", (r: NativeTagSnapshot) => (r.rich.checklistItems![0].text = "other")],
    ["checklist range", (r: NativeTagSnapshot) => (r.rich.checklistItems![0].start = 0)],
    [
      "extra checklist item",
      (r: NativeTagSnapshot) =>
        r.rich.checklistItems!.push({ id: "extra", text: "", done: false, start: 0 }),
    ],
    ["missing checklist metadata", (r: NativeTagSnapshot) => (r.rich.checklistItems = undefined)],
    ["missing object metadata", (r: NativeTagSnapshot) => (r.rich.objectData = undefined)],
    ["missing object raw label", (r: NativeTagSnapshot) => delete r.rich.objectData![0].altText],
  ] as const)("rejects changed %s despite retained IDs and presence flags", (_name, change) => {
    const { after, deps } = nativeFixture();
    change(after);
    try {
      addNativeTags(request, deps);
      expect.fail("Expected failed preservation");
    } catch (error) {
      expect(classifyError((error as Error).message, error)).toEqual({
        code: "verification_failed",
        indeterminate: true,
      });
    }
    expect(deps.run).toHaveBeenCalledTimes(1);
  });

  it.each(["objects", "objectData", "checklistItems", "styleRuns", "nativeTagObjectIds"] as const)(
    "refuses a write when existing %s cannot be verified",
    (field) => {
      const { before, deps } = nativeFixture();
      before.rich[field] = undefined;
      expect(() => addNativeTags(request, deps)).toThrow(/preservation metadata is unavailable/);
      expect(deps.run).not.toHaveBeenCalled();
    }
  );

  it.each([" ", "\t", "\n\n", "\r\n", "\u00a0", "\ufffc"])(
    "rejects deletion of retained whitespace or an unrelated placeholder: %j",
    (text) => {
      const f = fixture();
      const start = f.before.rich.text.indexOf("#shamaal");
      replaceText(f.before, start, 0, text);
      replaceText(f.after, start, 0, text);
      replaceText(f.after, start, text.length, "");
      expect(() => addNativeTags(request, f.deps)).toThrow(/not verified/);
      expect(f.deps.run).toHaveBeenCalledTimes(1);
    }
  );

  it("preserves trailing original whitespace when tags append", () => {
    const f = fixture();
    const end = f.before.rich.text.length;
    replaceText(f.before, end, 0, " \t\n\n");
    replaceText(f.after, end, 0, " \t\n\n");
    expect(addNativeTags(request, f.deps).added).toEqual(request.tags);
    const lost = fixture();
    replaceText(lost.before, lost.before.rich.text.length, 0, " \t\n\n");
    expect(() => addNativeTags(request, lost.deps)).toThrow(/not verified/);
  });

  it("rejects deleting a requested literal hashtag when its new pill is appended elsewhere", () => {
    const { after, deps } = fixture();
    replaceText(after, after.rich.text.indexOf("#shamaal"), "#shamaal".length, "");
    expect(() => addNativeTags(request, deps)).toThrow(/not verified/);
  });

  it("rejects deleting a literal hashtag for a pre-existing native tag", () => {
    const f = existingTagFixture();
    replaceText(f.before, 0, 0, "#existing ");
    replaceText(f.after, 0, 0, "#existing ");
    replaceText(f.after, 0, "#existing ".length, " ");
    expect(() => addNativeTags(request, f.deps)).toThrow(/not verified/);
  });

  it.each([
    "foo#shamaal",
    "##shamaal",
    "#shamaal-other",
    "#shamaalЖ",
    "𝒜#shamaal",
    "#shamaal𝒜",
    "#shamaal\u0301",
  ])("rejects conversion of a substring without complete Unicode tag boundaries: %s", (token) => {
    const f = nativeFixture();
    const start = f.before.rich.text.indexOf("#shamaal");
    replaceText(f.before, start, "#shamaal".length, token);
    const literalStart = token.indexOf("#shamaal");
    replaceText(f.after, start, 0, token.slice(0, literalStart));
    replaceText(f.after, start + literalStart + 1, 0, token.slice(literalStart + 8));
    expect(() => addNativeTags(request, f.deps)).toThrow(/not verified/);
  });

  it.each(["com.apple.notes.table", "com.apple.drawing.2", "hashtag", "unknown"])(
    "rejects a new object whose type is not the proven native tag UTI: %s",
    (type) => {
      const { after, deps } = fixture();
      after.rich.objects![0].type = type;
      after.rich.objectData![0].type = type;
      expect(() => addNativeTags(request, deps)).toThrow(/not verified/);
    }
  );

  it.each([
    ["unmapped pill", (r: NativeTagSnapshot) => delete r.rich.nativeTagObjectIds!.shamaal],
    ["wrong tag identity", (r: NativeTagSnapshot) => (r.rich.nativeTagObjectIds!.shamaal = ["b"])],
    [
      "unknown rendering",
      (r: NativeTagSnapshot) => replaceText(r, r.rich.objects![0].start, 1, "?"),
    ],
    ["missing raw tag label", (r: NativeTagSnapshot) => delete r.rich.objectData![0].altText],
    ["unrequested tag", (r: NativeTagSnapshot) => r.rich.nativeTags.push("extra")],
    ["missing style range", (r: NativeTagSnapshot) => (r.rich.styleRuns![0].length -= 1)],
    [
      "conflicting duplicate object rows",
      (r: NativeTagSnapshot) => (r.rich.nativeObjectDataComplete = false),
    ],
  ] as const)("rejects an unproven native-tag delta: %s", (_name, change) => {
    const { after, deps } = fixture();
    change(after);
    expect(() => addNativeTags(request, deps)).toThrow(/not verified/);
    expect(deps.run).toHaveBeenCalledTimes(1);
  });

  it("rejects an extra non-tag object while every requested tag is verified", () => {
    const { after, deps } = fixture();
    const start = after.rich.text.length;
    after.rich.text += "\n\ufffc";
    after.rich.objects!.push({
      id: "new-table",
      type: "com.apple.notes.table",
      start: start + 1,
      length: 1,
    });
    after.rich.nativeObjectIds.push("new-table");
    after.rich.objectData!.push({
      id: "new-table",
      type: "com.apple.notes.table",
      pk: 5,
      mergeable: "AA",
      view: 1,
      altText: null,
    });
    after.rich.styleRuns = styles(after.rich.text);
    expect(() => addNativeTags(request, deps)).toThrow(/not verified/);
  });

  it.each([
    ["payload", (r: NativeTagSnapshot) => (r.rich.objectData![0].mergeable = "CC")],
    ["raw label", (r: NativeTagSnapshot) => (r.rich.objectData![0].altText = "existing")],
    [
      "tag mapping",
      (r: NativeTagSnapshot) => {
        r.rich.nativeTagObjectIds!.existing = ["a"];
        r.rich.nativeTagObjectIds!.shamaal = ["table"];
      },
    ],
  ] as const)("rejects mutation of an existing pill's %s", (_name, change) => {
    const { after, deps } = existingTagFixture();
    change(after);
    expect(() => addNativeTags(request, deps)).toThrow(/not verified/);
  });

  it("verifies shifted links after a conversion and rejects moving a link to an identical label", () => {
    const f = nativeFixture();
    const link = {
      text: "Checklist",
      url: "https://example.com/",
      start: f.before.rich.text.indexOf("Checklist"),
      length: 9,
    };
    f.before.rich.links.push(link);
    f.after.rich.links.push({ ...link, start: link.start - 7 });
    expect(addNativeTags(request, f.deps).added).toEqual(request.tags);
    const moved = fixture();
    replaceText(moved.before, 0, 0, "Идеи ");
    replaceText(moved.after, 0, 0, "Идеи ");
    moved.after.rich.links[0].start = 0;
    expect(() => addNativeTags(request, moved.deps)).toThrow(/not verified/);
  });

  it("accepts equivalent style runs split around a converted hashtag", () => {
    const { before, after, deps } = nativeFixture();
    const start = before.rich.text.indexOf("#shamaal");
    before.rich.styleRuns = [
      { start: 0, length: start, signature: "body" },
      { start, length: 8, signature: "italic" },
      { start: start + 8, length: before.rich.text.length - start - 8, signature: "body" },
    ];
    after.rich.styleRuns = [
      { start: 0, length: 5, signature: "body" },
      { start: 5, length: start - 5, signature: "body" },
      { start, length: 1, signature: "new native tag" },
      { start: start + 1, length: after.rich.text.length - start - 1, signature: "body" },
    ];
    expect(addNativeTags(request, deps).added).toEqual(request.tags);
  });

  it.each(["signature", "paragraphStyle", "blockQuote", "highlight"] as const)(
    "rejects a change to retained %s formatting",
    (field) => {
      const { after, deps } = nativeFixture();
      Object.assign(after.rich.styleRuns![0], { [field]: field === "signature" ? "bold" : 1 });
      expect(() => addNativeTags(request, deps)).toThrow(/not verified/);
    }
  );
  it("refuses conflicting duplicate object rows before dispatch", () => {
    const { before, deps } = nativeFixture();
    before.rich.nativeObjectDataComplete = false;
    expect(() => addNativeTags(request, deps)).toThrow(/preservation metadata is unavailable/);
    expect(deps.run).not.toHaveBeenCalled();
  });
  it("rechecks preservation metadata immediately before dispatch", () => {
    const { before, deps } = nativeFixture();
    const current = structuredClone(before);
    current.rich.nativeObjectDataComplete = false;
    deps.read.mockReset().mockReturnValueOnce(before).mockReturnValue(current);
    expect(() => addNativeTags(request, deps)).toThrow(/preservation metadata is unavailable/);
    expect(deps.run).not.toHaveBeenCalled();
  });
});
