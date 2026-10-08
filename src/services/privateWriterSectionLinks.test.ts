import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock(import("./privateWriter.js"), async (importOriginal) => ({
  ...(await importOriginal()),
  callPrivateWriter: vi.fn(),
}));
import {
  SECTION_LINKS_LIVE_VALIDATED,
  PrivateWriteError,
  WRITER_ACTIONS,
  callPrivateWriter,
} from "./privateWriter.js";
import { addSectionLink, addSectionLinkSchema } from "./privateWriterSectionLinks.js";

const NOTE = "D629A948-0C61-43BA-8FDE-04CD6DED38C7";
const OTHER = "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F";
const PID = "0B6E6F46-5C9E-4F7B-9E57-7D3C9A1E2F10";
const INLINE = "9A8B7C6D-5E4F-4A3B-9C2D-1E0F9A8B7C6D";
const F1 = "x-coredata://8FA9FE0E-3B93-4057-AD95-A0EB6D4B5F06/ICFolder/p1";
const F2 = "x-coredata://8FA9FE0E-3B93-4057-AD95-A0EB6D4B5F06/ICFolder/p2";
const REV = `r1:${"a".repeat(64)}`;
const REV2 = `r1:${"b".repeat(64)}`;
const URL = `applenotes://showNote?identifier=${NOTE}&paragraphID=${PID}`;
const UNVERIFIED = { env: { APPLE_NOTES_MCP_ALLOW_UNVERIFIED_SECTION_LINKS: "1" } } as never;

const updated = {
  status: "updated",
  committed: true,
  verified: true,
  identifier: NOTE,
  target: NOTE,
  selfLink: true,
  section: "Plans",
  targetStyleType: 1,
  paragraphId: PID,
  previousParagraphIdStatus: "shared",
  paragraphIdMinted: true,
  url: URL,
  token: URL,
  inlineAttachmentIdentifier: INLINE,
  position: "end",
  clearedSectionLinks: 0,
  revisionBefore: REV,
  revisionAfter: REV2,
  modificationDate: "2026-09-24T00:00:00.000Z",
  cloudSync: { available: true, inICloudAccount: true, uploadPending: true },
  pushScheduled: false,
  pushState: "awaiting_notes_app",
  syncHostRunning: true,
  storeKind: "copy",
};

function thrown(fn: () => unknown): PrivateWriteError {
  try {
    fn();
  } catch (error) {
    return error as PrivateWriteError;
  }
  throw new Error("expected a throw");
}

beforeEach(() => vi.clearAllMocks());

describe("addSectionLink", () => {
  it("keeps section-link writes unvalidated pending recorded live evidence", () => {
    expect(SECTION_LINKS_LIVE_VALIDATED).toBe(false);
  });
  it("is a write action in the writer table", () => {
    expect(WRITER_ACTIONS.add_section_link).toBe("write");
  });

  it("sends only the note and revision for the default first heading", () => {
    vi.mocked(callPrivateWriter).mockReturnValueOnce(updated);
    expect(addSectionLink({ identifier: NOTE, ifRevision: REV }, UNVERIFIED).url).toBe(URL);
    expect(vi.mocked(callPrivateWriter).mock.calls[0].slice(0, 2)).toEqual([
      "add_section_link",
      { identifier: NOTE, ifRevision: REV },
    ]);
  });

  it("treats a target equal to the note as a link within the note", () => {
    vi.mocked(callPrivateWriter).mockReturnValueOnce(updated);
    addSectionLink({ identifier: NOTE, target: NOTE.toLowerCase(), ifRevision: REV }, UNVERIFIED);
    expect(vi.mocked(callPrivateWriter).mock.calls[0][1]).toEqual({
      identifier: NOTE,
      ifRevision: REV,
    });
  });

  it("forwards every option for a link into another note", () => {
    vi.mocked(callPrivateWriter).mockReturnValueOnce({
      ...updated,
      target: OTHER,
      selfLink: false,
      targetRevisionBefore: REV,
      targetRevisionAfter: REV2,
    });
    addSectionLink(
      {
        identifier: NOTE,
        target: OTHER,
        blockIndex: 4,
        expectedText: "Plans",
        position: "belowTitle",
        clearExistingSectionLinks: true,
        ifRevision: REV,
        ifTargetRevision: REV2,
      },
      UNVERIFIED
    );
    expect(vi.mocked(callPrivateWriter).mock.calls[0][1]).toEqual({
      identifier: NOTE,
      target: OTHER,
      blockIndex: 4,
      expectedText: "Plans",
      position: "belowTitle",
      clearExistingSectionLinks: true,
      ifRevision: REV,
      ifTargetRevision: REV2,
    });
    vi.mocked(callPrivateWriter).mockReturnValueOnce(updated);
    addSectionLink(
      { identifier: NOTE, paragraphId: PID.toLowerCase(), ifRevision: REV },
      UNVERIFIED
    );
    expect(vi.mocked(callPrivateWriter).mock.calls[1][1]).toMatchObject({ paragraphId: PID });
    vi.mocked(callPrivateWriter).mockReturnValueOnce(updated);
    addSectionLink({ identifier: NOTE, heading: "Plans", ifRevision: REV }, UNVERIFIED);
    expect(vi.mocked(callPrivateWriter).mock.calls[2][1]).toMatchObject({ heading: "Plans" });
  });

  it("refuses bad input before spawning, with committed false", () => {
    const base = { identifier: NOTE, ifRevision: REV };
    for (const request of [
      { ...base, identifier: "nope" },
      { ...base, target: "nope" },
      { ...base, ifRevision: "r1:x" },
      { ...base, ifTargetRevision: REV },
      { ...base, target: OTHER },
      { ...base, target: OTHER, ifTargetRevision: "r1:x" },
      { ...base, heading: "a", paragraphId: PID },
      { ...base, blockIndex: 1, heading: "a", expectedText: "a" },
      { ...base, blockIndex: -1, expectedText: "a" },
      { ...base, blockIndex: 1 },
      { ...base, expectedText: "a" },
      { ...base, paragraphId: "nope" },
      { ...base, heading: "  " },
    ])
      expect(thrown(() => addSectionLink(request, UNVERIFIED))).toMatchObject({
        code: "invalid_request",
        committed: false,
      });
    expect(callPrivateWriter).not.toHaveBeenCalled();
  });

  it("forwards an independent target-only policy even for an already unique paragraph", () => {
    vi.mocked(callPrivateWriter).mockReturnValueOnce(updated);
    addSectionLink(
      {
        identifier: NOTE,
        target: OTHER,
        paragraphId: PID,
        ifRevision: REV,
        ifTargetRevision: REV2,
        targetScope: { ifAncestorFolderId: F2, forbiddenAncestorFolderIds: [F1] },
      },
      UNVERIFIED
    );
    expect(vi.mocked(callPrivateWriter).mock.calls[0][1]).toEqual({
      identifier: NOTE,
      target: OTHER,
      paragraphId: PID,
      ifRevision: REV,
      ifTargetRevision: REV2,
      targetScope: { ifAncestorFolderId: F2, forbiddenAncestorFolderIds: [F1] },
    });
  });

  it("requires a nonempty explicit target policy for a guarded cross-note call", () => {
    const request = {
      identifier: NOTE,
      target: OTHER,
      ifRevision: REV,
      ifTargetRevision: REV2,
      scope: { ifFolderId: F1 },
    };
    for (const targetScope of [undefined, {}, { forbiddenAncestorFolderIds: [] }])
      expect(thrown(() => addSectionLink({ ...request, targetScope }, UNVERIFIED))).toMatchObject({
        code: "invalid_request",
        committed: false,
      });
    expect(callPrivateWriter).not.toHaveBeenCalled();
    vi.mocked(callPrivateWriter).mockReturnValueOnce(updated);
    addSectionLink({ ...request, targetScope: { ifFolderId: F2 } }, UNVERIFIED);
    expect(vi.mocked(callPrivateWriter).mock.calls[0][1]).toMatchObject({
      ifFolderId: F1,
      targetScope: { ifFolderId: F2 },
    });
  });

  it("rejects malformed or unknown target guard fields before spawning", () => {
    for (const targetScope of [
      null,
      [],
      { ifFolderId: "" },
      { ifFolderId: "x-coredata://8FA9/ICNote/p1" },
      { forbiddenAncestorFolderIds: "bad" },
      { forbiddenAncestorFolderIds: Array(51).fill(F1) },
      { ifFolderId: F1, typo: true },
    ])
      expect(
        thrown(() =>
          addSectionLink({ identifier: NOTE, ifRevision: REV, targetScope } as never, UNVERIFIED)
        )
      ).toMatchObject({ code: "invalid_request", committed: false });
    expect(callPrivateWriter).not.toHaveBeenCalled();
  });

  it("uses one self-link subject, accepting target-only and equivalent policies", () => {
    for (const request of [
      { identifier: NOTE, ifRevision: REV, targetScope: { ifFolderId: F1 } },
      {
        identifier: NOTE,
        target: NOTE.toLowerCase(),
        ifRevision: REV,
        scope: { ifFolderId: F1, forbiddenAncestorFolderIds: [F1, F2] },
        targetScope: {
          ifFolderId: F1.replace("/p1", "/p01"),
          forbiddenAncestorFolderIds: [F2, F1, F2],
        },
      },
    ]) {
      vi.mocked(callPrivateWriter).mockReturnValueOnce(updated);
      addSectionLink(request, UNVERIFIED);
    }
    expect(vi.mocked(callPrivateWriter).mock.calls[0][1]).toEqual({
      identifier: NOTE,
      ifRevision: REV,
      ifFolderId: F1,
    });
    expect(vi.mocked(callPrivateWriter).mock.calls[1][1]).toMatchObject({
      ifFolderId: F1,
      forbiddenAncestorFolderIds: [F1, F2],
    });
    for (const targetScope of [{}, { ifFolderId: F2 }])
      expect(
        thrown(() =>
          addSectionLink(
            { identifier: NOTE, ifRevision: REV, scope: { ifFolderId: F1 }, targetScope },
            UNVERIFIED
          )
        )
      ).toMatchObject({ code: "invalid_request", committed: false });
    expect(callPrivateWriter).toHaveBeenCalledTimes(2);
  });

  it("needs APPLE_NOTES_MCP_ALLOW_UNVERIFIED_SECTION_LINKS until live-validated", () => {
    expect(
      thrown(() => addSectionLink({ identifier: NOTE, ifRevision: REV }, { env: {} } as never))
    ).toMatchObject({ code: "not_live_validated", committed: false });
  });

  it("treats a malformed success as indeterminate and requires sync fields", () => {
    vi.mocked(callPrivateWriter).mockReturnValueOnce({ ...updated, position: "middle" });
    expect(
      thrown(() => addSectionLink({ identifier: NOTE, ifRevision: REV }, UNVERIFIED))
    ).toMatchObject({ code: "invalid_response", committed: "unknown" });
    const { storeKind: _storeKind, ...noSync } = updated;
    void _storeKind;
    expect(addSectionLinkSchema.safeParse(noSync).success).toBe(false);
  });
});
