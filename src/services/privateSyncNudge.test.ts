/**
 * Sync-state reads and the move-in-place nudge. The writer is faked in
 * memory (installation files and spawn), and AppleScript, sleep, and the
 * clock are injected, so no Notes data is touched.
 */
import { describe, expect, it } from "vitest";
import type { spawnSync } from "node:child_process";
import { sha256Hex } from "./privateHelper.js";
import {
  MAX_SYNC_TARGETS,
  moveInPlaceScript,
  nudgeInPlace,
  nudgeRefusal,
  readSyncState,
  syncTargets,
  uploadRecorded,
  defaultNudgeDeps,
  type NudgeDeps,
  type SyncObjectState,
} from "./privateSyncNudge.js";
import {
  PRIVATE_WRITER_PROTOCOL,
  PrivateWriteError,
  WRITER_MANIFEST_NAME,
  defaultWriterDeps,
  type PrivateHelperDeps,
} from "./privateWriter.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const FOLDER = "11111111-2222-3333-4444-555555555555";
const NOTE_URI = "x-coredata://ABCDEF01-2345/ICNote/p42";
const FOLDER_URI = "x-coredata://ABCDEF01-2345/ICFolder/p7";

function noteState(overrides: Partial<SyncObjectState> = {}): SyncObjectState {
  return {
    identifier: NOTE,
    found: true,
    kind: "note",
    objectURI: NOTE_URI,
    markedForDeletion: false,
    inICloudAccount: true,
    cloudStateAvailable: true,
    currentLocalVersion: 5,
    latestVersionSyncedToCloud: 4,
    uploadPending: true,
    folderIdentifier: FOLDER,
    folderObjectURI: FOLDER_URI,
    passwordProtected: false,
    deletedOrInTrash: false,
    sharedViaICloud: false,
    revision: "r1:" + "a".repeat(64),
    ...overrides,
  };
}

/** In-memory writer: every read_sync_state call returns the next snapshot. */
function fakeWriter(snapshots: Array<Record<string, unknown>>, requests: unknown[] = []) {
  const manifest = JSON.stringify({
    schemaVersion: 1,
    protocolVersion: PRIVATE_WRITER_PROTOCOL,
    sourceSha256: sha256Hex("src"),
    binarySha256: sha256Hex("bin"),
    builtAt: "x",
    osVersion: "27.2",
    compiler: "clang",
  });
  let call = 0;
  const spawn = ((_bin: string, _args: string[], options: { input: string }) => {
    requests.push(JSON.parse(options.input));
    const snapshot = snapshots[Math.min(call++, snapshots.length - 1)];
    return { status: 0, stdout: JSON.stringify(snapshot), stderr: "", signal: null };
  }) as unknown as typeof spawnSync;
  const deps: PrivateHelperDeps = defaultWriterDeps({
    env: {
      APPLE_NOTES_MCP_ENABLE_PRIVATE: "1",
      APPLE_NOTES_MCP_ENABLE_PRIVATE_WRITES: "1",
      APPLE_NOTES_MCP_PRIVATE_HELPER_DIR: "/fake",
    },
    platform: "darwin",
    sourcePath: "/fake/src.m",
    exists: () => true,
    readFile: (path) =>
      Buffer.from(
        path.endsWith(WRITER_MANIFEST_NAME) ? manifest : path.endsWith(".m") ? "src" : "bin"
      ),
    spawn,
  });
  return deps;
}

function snapshot(objects: SyncObjectState[], extra: Record<string, unknown> = {}) {
  return { status: "ok", objects, pendingUploadCount: 3, syncHostRunning: true, ...extra };
}

function nudgeDeps(
  helper: PrivateHelperDeps,
  scripts: string[] = [],
  result = { success: true, output: "moved" } as {
    success: boolean;
    output: string;
    error?: string;
  }
): NudgeDeps {
  let clock = 0;
  return defaultNudgeDeps({
    helper,
    runAppleScript: (script) => {
      scripts.push(script);
      return result;
    },
    sleep: async (ms) => {
      clock += ms;
    },
    now: () => clock,
  });
}

describe("syncTargets and pure helpers", () => {
  it("validates and de-duplicates identifiers", () => {
    expect(syncTargets([NOTE, NOTE])).toEqual([NOTE]);
    expect(() => syncTargets([])).toThrow(PrivateWriteError);
    expect(() => syncTargets(["nope"])).toThrow(/UUIDs/);
    const many = Array.from(
      { length: MAX_SYNC_TARGETS + 1 },
      (_, i) => `00000000-0000-0000-0000-${String(i).padStart(12, "0")}`
    );
    expect(() => syncTargets(many)).toThrow(/1-50/);
  });

  it("uploadRecorded needs both counters and a caught-up sync version", () => {
    expect(uploadRecorded(noteState())).toBe(false);
    expect(uploadRecorded(noteState({ latestVersionSyncedToCloud: 5 }))).toBe(true);
    expect(uploadRecorded(noteState({ currentLocalVersion: undefined }))).toBe(false);
    expect(uploadRecorded(noteState({ found: false }))).toBe(false);
  });

  it("nudgeRefusal names every reason a note cannot be nudged", () => {
    expect(nudgeRefusal(noteState())).toBeNull();
    expect(nudgeRefusal({ identifier: NOTE, found: false })).toBe("not_found");
    expect(nudgeRefusal({ identifier: NOTE, found: false, reason: "ambiguous" })).toBe("ambiguous");
    expect(nudgeRefusal(noteState({ uploadPending: false }))).toBe("nothing_pending");
    expect(nudgeRefusal(noteState({ kind: "folder" }))).toBe("folders_need_relaunch");
    expect(nudgeRefusal(noteState({ inICloudAccount: false }))).toBe("not_icloud");
    expect(nudgeRefusal(noteState({ deletedOrInTrash: true }))).toBe("deleted");
    expect(nudgeRefusal(noteState({ markedForDeletion: true }))).toBe("deleted");
    expect(nudgeRefusal(noteState({ passwordProtected: true }))).toBe("locked");
    expect(nudgeRefusal(noteState({ sharedViaICloud: true }))).toBe("shared");
    expect(nudgeRefusal(noteState({ objectURI: "bogus" }))).toBe("no_object_id");
    expect(nudgeRefusal(noteState({ folderObjectURI: null }))).toBe("no_folder");
  });

  it("moveInPlaceScript embeds only validated object ids", () => {
    const script = moveInPlaceScript(NOTE_URI, FOLDER_URI);
    expect(script).toContain(`note id "${NOTE_URI}"`);
    expect(script).toContain(`is not "${FOLDER_URI}"`);
    expect(script).toContain("move theNote to theFolder");
    expect(() => moveInPlaceScript('x" & do shell script "y', FOLDER_URI)).toThrow(
      /unexpected object id/
    );
  });
});

describe("readSyncState", () => {
  it("sends read_sync_state and validates the answer", () => {
    const requests: unknown[] = [];
    const state = readSyncState([NOTE], fakeWriter([snapshot([noteState()])], requests));
    expect(state.objects[0].uploadPending).toBe(true);
    expect(requests[0]).toEqual({ protocol: 1, action: "read_sync_state", identifiers: [NOTE] });
    expect(() => readSyncState([NOTE], fakeWriter([{ status: "ok" }]))).toThrow(
      /Unexpected writer response/
    );
  });
});

describe("nudgeInPlace", () => {
  it("moves a pending note in place and watches until the upload is recorded", async () => {
    const scripts: string[] = [];
    const helper = fakeWriter([
      snapshot([noteState()]),
      snapshot([noteState()]),
      snapshot([noteState({ latestVersionSyncedToCloud: 5, uploadPending: false })], {
        pendingUploadCount: 2,
      }),
    ]);
    const report = await nudgeInPlace({ identifiers: [NOTE] }, nudgeDeps(helper, scripts));
    expect(scripts).toHaveLength(1);
    expect(report.targets[0]).toMatchObject({
      action: "moved_in_place",
      uploadRecorded: true,
      contentUnchanged: true,
      uploadPendingBefore: true,
    });
    expect(report).toMatchObject({
      allUploadsRecorded: true,
      pushScheduled: false,
      pendingUploadCountBefore: 3,
      pendingUploadCountAfter: 2,
      waitedSeconds: 2,
    });
    expect(report.warnings).toEqual([]);
  });

  it("warns when content changed during the nudge or the upload stays pending", async () => {
    const helper = fakeWriter([
      snapshot([noteState()]),
      snapshot([noteState({ revision: "r1:" + "f".repeat(64) })]),
    ]);
    const report = await nudgeInPlace({ identifiers: [NOTE], waitSeconds: 4 }, nudgeDeps(helper));
    expect(report.targets[0].contentUnchanged).toBe(false);
    expect(report.allUploadsRecorded).toBe(false);
    expect(report.warnings.join("\n")).toMatch(/revision changed/);
    expect(report.warnings.join("\n")).toMatch(/still show a pending upload after 4 s/);
    expect(report.waitedSeconds).toBe(4);
  });

  it("skips targets it cannot nudge and reports failed moves", async () => {
    const other = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
    const helper = fakeWriter([
      snapshot([
        noteState({ passwordProtected: true }),
        { identifier: other, found: false, reason: "not_found" },
      ]),
    ]);
    const report = await nudgeInPlace(
      { identifiers: [NOTE, other], waitSeconds: 0 },
      nudgeDeps(helper)
    );
    expect(report.targets[0]).toMatchObject({ action: "skipped", reason: "locked" });
    expect(report.targets[1]).toMatchObject({ action: "none", reason: "not_found" });

    const failing = fakeWriter([snapshot([noteState()])]);
    const changed = await nudgeInPlace(
      { identifiers: [NOTE], waitSeconds: 0 },
      nudgeDeps(failing, [], { success: false, output: "", error: "container changed (9901)" })
    );
    expect(changed.targets[0]).toMatchObject({ action: "failed", reason: "container_changed" });
    const other2 = await nudgeInPlace(
      { identifiers: [NOTE], waitSeconds: 0 },
      nudgeDeps(fakeWriter([snapshot([noteState()])]), [], { success: true, output: "odd" })
    );
    expect(other2.targets[0].reason).toMatch(/^applescript: odd/);
  });

  it("does nothing but read when Notes.app is not running or nudge is false", async () => {
    const scripts: string[] = [];
    const notRunning = await nudgeInPlace(
      { identifiers: [NOTE], waitSeconds: 0 },
      nudgeDeps(fakeWriter([snapshot([noteState()], { syncHostRunning: false })]), scripts)
    );
    expect(notRunning.warnings[0]).toMatch(/not running/);
    const readOnly = await nudgeInPlace(
      { identifiers: [NOTE], nudge: false },
      nudgeDeps(fakeWriter([snapshot([noteState()])]), scripts)
    );
    expect(readOnly.waitedSeconds).toBe(0);
    expect(readOnly.targets[0].action).toBe("none");
    expect(scripts).toEqual([]);
  });

  it("rejects an out-of-range wait before reading anything", async () => {
    await expect(
      nudgeInPlace({ identifiers: [NOTE], waitSeconds: 999 }, nudgeDeps(fakeWriter([])))
    ).rejects.toThrow(/waitSeconds/);
  });

  it("has real defaults for AppleScript, sleep, and the clock", async () => {
    const real = defaultNudgeDeps();
    expect(typeof real.runAppleScript).toBe("function");
    expect(real.now()).toBeGreaterThan(0);
    await expect(real.sleep(1)).resolves.toBeUndefined();
  });
});
