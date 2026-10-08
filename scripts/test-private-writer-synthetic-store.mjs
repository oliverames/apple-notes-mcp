#!/usr/bin/env node
/** Real NotesShared writes against a fresh synthetic store; no personal store input.
 * Keeps evidence in a new private temporary directory. Never copies/discovers a
 * live store, overrides HOME, grants permissions, or calls Notes.app automation.
 */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { gunzipSync } from "node:zlib";
import {
  buildSyntheticNotePayload,
  text,
  noteIdentifier,
  replicaIdentifier,
} from "./lib/synthetic-note-payload.mjs";
import { writerSourceClosure } from "./lib/writer-source-closure.mjs";
import { readSingleLinkFile } from "./lib/synthetic-fixture-files.mjs";
import { snapshotSyntheticTree, summarizeSyntheticTree } from "./lib/synthetic-store-snapshot.mjs";

if (process.argv.length !== 2)
  throw new Error("This fixture test accepts no paths or private input");
if (process.platform !== "darwin") throw new Error("Real Notes model validation requires macOS");
const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const root = realpathSync(mkdtempSync("/private/tmp/apple-notes-synthetic-fixture-"));
chmodSync(root, 0o700);
const hash = (value) => createHash("sha256").update(value).digest("hex");
const persist = (name, value) =>
  writeFileSync(join(root, name), JSON.stringify(value, null, 2) + "\n", { mode: 0o600 });
const report = {
  schemaVersion: 1,
  kind: "generated-synthetic-store",
  syntheticOnly: true,
  personalStoreRead: false,
  fixtureSeedPublic: true,
  nativeOutputPrivacyReviewed: false,
  isolatedCachesPrecreated: true,
  tests: [],
  mutationChecks: [],
  completed: false,
};
persist("report.json", report);
function command(binary, args, options = {}) {
  const r = spawnSync(binary, args, {
    encoding: "utf8",
    timeout: 120000,
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  });
  if (r.error || r.status !== 0)
    throw new Error(`${binary} failed: ${r.error?.message ?? r.status}; ${r.stderr ?? ""}`);
  return r;
}
function test(name, fn) {
  fn();
  report.tests.push(name);
  persist("report.json", report);
}
const privateUser = join(root, "isolated-user");
mkdirSync(join(privateUser, "Library/Preferences"), { recursive: true, mode: 0o700 });
// File-type resolution may initialize an otherwise empty user Caches folder.
// Supply this ordinary infrastructure before preflight, without excluding any
// native cache content or later directory changes from exact tree comparisons.
mkdirSync(join(privateUser, "Library/Caches"), { recursive: true, mode: 0o700 });
mkdirSync(join(root, "tmp"), { mode: 0o700 });
const profile = join(root, "fixture.sb");
// Allow runtime primitive operations but deny every filesystem path except
// explicit system files + this fresh root. All Mach services and network are
// denied, including cfprefsd (whose daemon could write outside the sandbox).
writeFileSync(
  profile,
  `(version 1)\n(allow default)\n(deny network*)\n(deny mach-lookup)\n(deny mach-register)\n` +
    `(deny file-read* (require-not (require-any (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") ` +
    `(subpath "/private/etc") (subpath "/Library/Apple") (literal "/") (literal "/private") (literal "/private/tmp") ` +
    `(literal "/tmp") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom") (subpath ${JSON.stringify(root)}))))\n` +
    `(deny file-write* (require-not (subpath ${JSON.stringify(root)})))\n`,
  { mode: 0o600 }
);
const childEnv = { ...process.env, CFFIXED_USER_HOME: privateUser, TMPDIR: join(root, "tmp") };
for (const key of Object.keys(childEnv))
  if (key.startsWith("APPLE_NOTES_MCP_")) delete childEnv[key];
const sandbox = (binary, args = [], options = {}) =>
  command("/usr/bin/sandbox-exec", ["-f", profile, binary, ...args], {
    ...options,
    env: { ...childEnv, ...options.env },
    cwd: root,
  });
const compile = (source, output, frameworks) =>
  command(
    "/usr/bin/xcrun",
    [
      "clang",
      "-fobjc-arc",
      "-O2",
      "-Wall",
      ...frameworks.flatMap((name) => ["-framework", name]),
      source,
      "-o",
      output,
    ],
    { timeout: 180000 }
  );
try {
  const probe = join(root, "isolation-probe");
  compile(join(repo, "scripts/lib/replica-isolation-probe.m"), probe, ["Foundation"]);
  report.isolation = JSON.parse(sandbox(probe).stdout);
  test("filesystem, preference-service, network and fixed-home preflight", () => {
    for (const key of [
      "realHomeDenied",
      "globalPreferencesDenied",
      "preferencesDaemonDenied",
      "networkDenied",
      "fixedUserHomeVerified",
      "productionBundleVerified",
    ])
      assert.equal(report.isolation[key], true);
    assert.notEqual(privateUser, homedir());
    assert.equal(childEnv.HOME, process.env.HOME);
  });
  const payload = buildSyntheticNotePayload();
  const payloadPath = join(root, "generated-baseline.gz");
  writeFileSync(payloadPath, payload, { mode: 0o600 });
  report.baselinePayloadSha256 = hash(payload);
  const generator = join(root, "generator");
  const generatorSource = join(repo, "test/native/synthetic-notes-store.m");
  const modelPath =
    "/System/Library/PrivateFrameworks/NotesShared.framework/Resources/NoteData.mom";
  const generatorBytes = readFileSync(generatorSource);
  assert.ok(
    generatorBytes.includes(Buffer.from(modelPath)),
    "generator uses the recorded system model"
  );
  report.model = {
    path: modelPath,
    resolvedPath: realpathSync(modelPath),
    sha256: hash(readFileSync(modelPath)),
  };
  compile(generatorSource, generator, ["Foundation", "CoreData"]);
  report.generatorBinarySha256 = hash(readFileSync(generator));
  const store = join(root, "NoteStore.sqlite");
  const generated = sandbox(generator, [
    store,
    payloadPath,
    noteIdentifier,
    replicaIdentifier,
    "--receipt-fixture",
  ]);
  writeFileSync(join(root, "generator.stderr"), generated.stderr, { mode: 0o600 });
  report.generator = JSON.parse(generated.stdout);
  report.generatorSourceSha256 = hash(generatorBytes);
  const initialStoreBytes = readSingleLinkFile(store);
  const sqlite = (query) => command("/usr/bin/sqlite3", ["-readonly", store, query]).stdout.trim();
  const body = () => Buffer.from(sqlite("SELECT hex(ZDATA) FROM ZICNOTEDATA;"), "hex");
  test("one synthetic note, account, four scope folders and hidden inline row; exact baseline", () => {
    assert.deepEqual(report.generator, {
      created: true,
      frameworkLoaded: false,
      notes: 1,
      accounts: 1,
      folders: 4,
      inlineAttachments: 1,
    });
    assert.equal(sqlite("PRAGMA integrity_check;"), "ok");
    assert.equal(sqlite("SELECT count(*) FROM ZICNOTEDATA;"), "1");
    assert.equal(sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT;"), "7");
    assert.equal(
      sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTYPEUTI IS NOT NULL;"),
      "1"
    );
    assert.equal(hash(body()), hash(payload));
    assert.ok(!existsSync(store + "-wal") && !existsSync(store + "-shm"));
    assert.ok(!initialStoreBytes.includes(Buffer.from(process.env.HOME ?? "/Users/")));
    assert.ok(!initialStoreBytes.includes(Buffer.from("group.com.apple.notes")));
  });
  // The generator has closed the journal-free database and no writer has run.
  report.initialStoreSha256 = hash(initialStoreBytes);
  const decoder = join(root, "decoder.mjs");
  // Import only pure decoders. No store reader or Notes.app API is called;
  // their input is the fresh synthetic store's explicitly selected ZDATA.
  const decoderEntry = [
    ["parseNoteReplicaTable", "noteReplicaTable.ts"],
    ["decodeNoteBody", "noteQueryStore.ts"],
    ["decodeNoteBlocks", "noteBlocks.ts"],
  ]
    .map(
      ([name, file]) => `export { ${name} } from ${JSON.stringify(join(repo, "src/utils", file))};`
    )
    .join("\n");
  command(
    join(repo, "node_modules/.bin/esbuild"),
    [
      "--bundle",
      "--platform=node",
      "--format=esm",
      `--tsconfig=${join(repo, "tsconfig.json")}`,
      `--outfile=${decoder}`,
      "--log-level=error",
    ],
    { input: decoderEntry }
  );
  const { parseNoteReplicaTable, decodeNoteBody, decodeNoteBlocks } = await import(
    pathToFileURL(decoder).href
  );
  const checkDecoded = (expectedText) => {
    const stored = body();
    const plain = gunzipSync(stored);
    assert.equal(
      decodeNoteBody(plain)?.text,
      expectedText,
      "independent stored plaintext equals the entire expected body"
    );
    const blocks = decodeNoteBlocks(plain);
    assert.equal(blocks.text, expectedText, "strict block decoder agrees on the complete body");
    const table = parseNoteReplicaTable(stored);
    assert.equal(table.layout.lengthsMatchText, true);
    assert.deepEqual(table.layout.warnings, []);
    assert.deepEqual(table.layout.unmappedReplicaIds, []);
    return { table, blocks };
  };
  test("generated CRDT has exact text length and one synthetic owner", () => {
    const { table } = checkDecoded(text);
    assert.equal(table.layout.textUtf16, text.length);
    assert.deepEqual(
      table.replicas.map((row) => row.uuid),
      [replicaIdentifier]
    );
  });
  const writer = join(root, "writer");
  const writerSource = join(repo, "native/private-helper/apple-notes-private-writer.m");
  compile(writerSource, writer, ["Foundation", "CoreData", "AppKit", "PencilKit"]);
  report.writerSourceClosure = writerSourceClosure(writerSource);
  report.writerSourceSha256 = report.writerSourceClosure.sha256;
  report.writerBinarySha256 = hash(readFileSync(writer));
  const writerEnv = { APPLE_NOTES_MCP_ENABLE_PRIVATE: "1", APPLE_NOTES_MCP_PRIVATE_STORE: store };
  let invocation = 0;
  // Only filenames written by this harness are excluded, never native media,
  // preferences, temporary files, database journals or other materialization.
  const evidenceFiles = new Set(["report.json"]);
  function call(action, fields = {}, feature, expectedError) {
    invocation++;
    const env = { ...writerEnv };
    if (feature) env[`APPLE_NOTES_MCP_ALLOW_UNVERIFIED_${feature}`] = "1";
    const result = spawnSync("/usr/bin/sandbox-exec", ["-f", profile, writer], {
      encoding: "utf8",
      timeout: 120000,
      env: { ...childEnv, ...env },
      cwd: root,
      input: JSON.stringify({ protocol: 1, action, ...fields }),
    });
    evidenceFiles.add(`writer-${invocation}.stderr`);
    evidenceFiles.add(`writer-${invocation}.json`);
    writeFileSync(join(root, `writer-${invocation}.stderr`), result.stderr ?? "", { mode: 0o600 });
    if (result.error) throw result.error;
    const response = JSON.parse(result.stdout);
    persist(`writer-${invocation}.json`, response);
    if (expectedError && (!Array.isArray(expectedError) || response.status === "error")) {
      assert.equal(result.status, 1);
      assert.equal(response.status, "error");
      if (Array.isArray(expectedError)) assert.ok(expectedError.includes(response.code));
      else assert.equal(response.code, expectedError);
      assert.equal(response.committed, false);
    } else {
      assert.equal(result.status, 0, JSON.stringify(response));
      assert.notEqual(response.status, "error");
      // read_note_state has no storeKind field in the native protocol. Every
      // write or plan must explicitly confirm that it opened the copy store.
      if (action !== "read_note_state") assert.equal(response.storeKind, "copy");
      assert.equal(response.identifier, noteIdentifier);
    }
    return response;
  }
  const read = () => call("read_note_state", { identifier: noteIdentifier });
  function snapshot() {
    return {
      storeSha256: hash(readSingleLinkFile(store)),
      bodySha256: hash(body()),
      // Covers every persistent table, property, relationship and metadata
      // value independently of the native revision token.
      databaseDumpSha256: hash(sqlite(".dump")),
      entityPopulation: sqlite(
        "SELECT Z_ENT,count(*) FROM ZICCLOUDSYNCINGOBJECT GROUP BY Z_ENT ORDER BY Z_ENT;"
      ),
      tree: snapshotSyntheticTree(root, evidenceFiles),
    };
  }
  function unchanged(name, expectedText, fn) {
    const beforeState = read();
    const before = snapshot();
    const result = fn();
    assert.deepEqual(
      snapshot(),
      before,
      "refusal/plan/no-op must preserve exact store, objects and scratch files"
    );
    assert.equal(read().revision, beforeState.revision);
    checkDecoded(expectedText);
    assert.deepEqual(
      snapshot(),
      before,
      "independent read-back must also leave the store and scratch unchanged"
    );
    const { tree, ...countsAndHashes } = before;
    report.mutationChecks.push({
      name,
      ...countsAndHashes,
      tree: summarizeSyntheticTree(tree),
      unchanged: true,
    });
    return result;
  }
  let state = read();
  test("actual NotesShared opens generated model, body and editable note", () => {
    assert.equal(state.bodyLengthUTF16, text.length);
    assert.equal(state.editable, true);
    assert.equal(state.bodyAvailable, true);
  });
  test("direct writer append refuses absent feature opt-in without mutation", () => {
    call(
      "append_plain_text",
      { identifier: noteIdentifier, ifRevision: state.revision, text: "GATED" },
      undefined,
      "not_live_validated"
    );
    assert.equal(read().revision, state.revision);
    checkDecoded(text);
  });
  const appendText = "SYNTHETIC APPEND PROOF";
  let afterAppend = text + appendText;
  test("actual append preserves the baseline and stores exactly the requested text", () => {
    const changed = call(
      "append_plain_text",
      { identifier: noteIdentifier, ifRevision: state.revision, text: appendText },
      "APPEND"
    );
    assert.equal(changed.committed, true);
    assert.equal(changed.verified, true);
    state = read();
    assert.equal(state.bodyLengthUTF16, afterAppend.length);
    checkDecoded(afterAppend);
  });
  // Folder row numbers and the fresh store UUID are discovered only inside
  // this generated database; no production folder IDs are accepted as input.
  const storeURI = state.objectURI.split("/ICNote/")[0];
  assert.match(storeURI, /^x-coredata:\/\/[0-9A-Fa-f-]+$/);
  const folderURI = (identifier) => {
    const pk = sqlite(`SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE ZIDENTIFIER='${identifier}';`);
    assert.match(pk, /^[0-9]+$/);
    return `${storeURI}/ICFolder/p${pk}`;
  };
  const targetFolder = folderURI("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB");
  const parentFolder = folderURI("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC");
  const forbidden = [
    folderURI("DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD"),
    folderURI("EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE"),
  ];
  const strongScope = {
    ifFolderId: targetFolder,
    ifAncestorFolderId: parentFolder,
    forbiddenAncestorFolderIds: forbidden,
  };
  const without = (key) =>
    Object.fromEntries(Object.entries(strongScope).filter(([name]) => name !== key));
  const weakenedScopes = [
    ["omitted exact folder", without("ifFolderId")],
    ["omitted ancestor folder", without("ifAncestorFolderId")],
    ["omitted forbidden list", without("forbiddenAncestorFolderIds")],
    [
      "removed first forbidden folder",
      { ...strongScope, forbiddenAncestorFolderIds: [forbidden[1]] },
    ],
    [
      "removed second forbidden folder",
      { ...strongScope, forbiddenAncestorFolderIds: [forbidden[0]] },
    ],
    ["empty forbidden list", { ...strongScope, forbiddenAncestorFolderIds: [] }],
    ["removed all scope guards", {}],
  ];
  const editRequest = (replacementText) => ({
    identifier: noteIdentifier,
    operations: [
      {
        op: "replace",
        selector: { kind: "text", text: appendText, match: "equals" },
        replacement: { text: replacementText },
        expectedCount: 1,
      },
    ],
  });
  // Forward all reviewed fields unchanged. Later digest contracts can add a
  // receipt here without silently discarding it at the plan/apply boundary.
  const applyFields = (fields, plan) => ({
    ...fields,
    ifRevision: plan.revisionBefore,
    ifPlanDigest: plan.planDigest,
    ifAttachmentSnapshot: plan.attachmentSnapshot,
  });
  const changedText = "SYNTHETIC EDIT PROOF";
  const changingEdit = editRequest(changedText);
  const noOpEdit = editRequest(appendText);
  let changingControl;
  let noOpControl;
  for (const [kind, edit, wouldChange] of [
    ["changing edit", changingEdit, true],
    ["no-op edit", noOpEdit, false],
  ]) {
    const reviewed = { ...edit, ...strongScope };
    let reviewedPlan;
    test(`p4 ${kind} strong scope plan is read-only`, () => {
      reviewedPlan = unchanged(`${kind}: strong scope plan`, afterAppend, () =>
        call("plan_edit", reviewed)
      );
      assert.equal(reviewedPlan.status, "planned");
      assert.equal(reviewedPlan.committed, false);
      assert.equal(reviewedPlan.wouldChange, wouldChange);
      assert.equal(reviewedPlan.revisionBefore, state.revision);
      assert.match(reviewedPlan.planDigest, /^p4:[0-9a-f]{64}$/);
      assert.match(reviewedPlan.attachmentSnapshot, /^a1:[0-9a-f]{64}$/);
      assert.equal(reviewedPlan.frozenAttachments.inlineAttachments, 1);
      assert.equal(reviewedPlan.frozenAttachments.filesHashed, 0);
      assert.equal(reviewedPlan.attachmentGlyphs, 0);
    });
    for (const [label, scope] of weakenedScopes) {
      test(`p4 ${kind} refuses ${label} with exact mutation checks`, () => {
        const refused = unchanged(`${kind}: ${label}`, afterAppend, () =>
          call(
            "edit_note",
            applyFields({ ...edit, ...scope }, reviewedPlan),
            "EDIT",
            "plan_mismatch"
          )
        );
        assert.notEqual(refused.planDigest, reviewedPlan.planDigest);
      });
    }
    test(`p4 ${kind} refuses missing and mismatched digest before any persistent change`, () => {
      unchanged(`${kind}: missing digest`, afterAppend, () =>
        call(
          "edit_note",
          {
            ...reviewed,
            ifRevision: reviewedPlan.revisionBefore,
            ifAttachmentSnapshot: reviewedPlan.attachmentSnapshot,
          },
          "EDIT",
          "invalid_request"
        )
      );
      unchanged(`${kind}: mismatched digest`, afterAppend, () =>
        call(
          "edit_note",
          { ...applyFields(reviewed, reviewedPlan), ifPlanDigest: "p4:" + "0".repeat(64) },
          "EDIT",
          "plan_mismatch"
        )
      );
    });
    test(`a1 ${kind} refuses missing and mismatched receipt without mutation`, () => {
      const fields = applyFields(reviewed, reviewedPlan);
      const { ifAttachmentSnapshot, ...missing } = fields;
      unchanged(`${kind}: missing attachment receipt`, afterAppend, () =>
        call("edit_note", missing, "EDIT", "invalid_request")
      );
      unchanged(`${kind}: mismatched attachment receipt`, afterAppend, () =>
        call(
          "edit_note",
          { ...fields, ifAttachmentSnapshot: "a1:" + "0".repeat(64) },
          "EDIT",
          "attachment_snapshot_mismatch"
        )
      );
    });
    if (!wouldChange) {
      noOpControl = { fields: reviewed, plan: reviewedPlan };
      test("p4 identical strong-scope no-op returns unchanged without mutation", () => {
        const result = unchanged("no-op edit: exact positive control", afterAppend, () =>
          call("edit_note", applyFields(reviewed, reviewedPlan), "EDIT")
        );
        assert.equal(result.status, "unchanged");
        assert.equal(result.committed, false);
        assert.equal(result.revisionAfter, state.revision);
        assert.equal(result.planDigest, reviewedPlan.planDigest);
      });
    } else {
      // Run the changing positive control only after the no-op matrix, so
      // both suites compare the same loaded note revision.
      report.changingEditPlanDigestSha256 = hash(reviewedPlan.planDigest);
      report.changingEditRevisionSha256 = hash(reviewedPlan.revisionBefore);
      changingControl = { fields: reviewed, plan: reviewedPlan };
    }
  }
  let mutationInvocation = 0;
  const mutateInline = (mode) => {
    const before = read();
    const beforeBody = hash(body());
    mutationInvocation++;
    const result = sandbox(generator, [
      store,
      payloadPath,
      noteIdentifier,
      replicaIdentifier,
      mode,
    ]);
    const name = `generated-mutation-${mutationInvocation}`;
    evidenceFiles.add(`${name}.stderr`);
    evidenceFiles.add(`${name}.json`);
    writeFileSync(join(root, `${name}.stderr`), result.stderr, { mode: 0o600 });
    const response = JSON.parse(result.stdout);
    persist(`${name}.json`, response);
    assert.deepEqual(response, {
      mutated: true,
      frameworkLoaded: false,
      bodyPreserved: true,
      modificationDatePreserved: true,
    });
    assert.equal(hash(body()), beforeBody);
    assert.equal(read().revision, before.revision);
    checkDecoded(afterAppend);
  };
  report.attachmentDrift = [];
  for (const [label, mode, rows] of [
    ["hidden inline stored token", "--inline-token", 1],
    ["hidden inline tombstone", "--inline-tombstone", 1],
    ["additional hidden owned inline row", "--inline-add-hidden", 2],
  ]) {
    test(`a1 detects ${label} while r1 and operations stay constant`, () => {
      const before = read();
      const beforeBody = hash(body());
      mutateInline(mode);
      const fresh = unchanged(`${label}: fresh read-only plan`, afterAppend, () =>
        call("plan_edit", changingControl.fields)
      );
      assert.equal(fresh.revisionBefore, before.revision);
      assert.equal(hash(body()), beforeBody);
      assert.equal(fresh.frozenAttachments.inlineAttachments, rows);
      assert.notEqual(fresh.attachmentSnapshot, changingControl.plan.attachmentSnapshot);
      assert.notEqual(fresh.planDigest, changingControl.plan.planDigest);
      for (const [kind, reviewed] of [
        ["changing edit", changingControl],
        ["no-op edit", noOpControl],
      ]) {
        unchanged(`${label}: stale a1 ${kind} before materialization`, afterAppend, () =>
          call(
            "edit_note",
            applyFields(reviewed.fields, reviewed.plan),
            "EDIT",
            "attachment_snapshot_mismatch"
          )
        );
      }
      report.attachmentDrift.push({
        kind: label,
        revisionUnchanged: true,
        bodyUnchanged: true,
        operationsUnchanged: true,
        ownedInlineRows: rows,
        priorReceiptSha256: hash(changingControl.plan.attachmentSnapshot),
        freshReceiptSha256: hash(fresh.attachmentSnapshot),
        staleChangingAndNoOpRefused: true,
      });
      mutateInline("--inline-restore");
      const restored = unchanged(`${label}: restored public row plan`, afterAppend, () =>
        call("plan_edit", changingControl.fields)
      );
      assert.equal(restored.attachmentSnapshot, changingControl.plan.attachmentSnapshot);
      assert.equal(restored.planDigest, changingControl.plan.planDigest);
    });
  }
  test("p4 identical strong-scope real edit commits and independently verifies exact body", () => {
    const beforePopulation = sqlite(
      "SELECT Z_ENT,count(*) FROM ZICCLOUDSYNCINGOBJECT GROUP BY Z_ENT ORDER BY Z_ENT;"
    );
    const changed = call(
      "edit_note",
      applyFields(changingControl.fields, changingControl.plan),
      "EDIT"
    );
    assert.equal(changed.status, "updated");
    assert.equal(changed.committed, true);
    assert.equal(changed.verified, true);
    assert.equal(changed.planDigest, changingControl.plan.planDigest);
    assert.equal(changed.preservation.formattingOutsideEditsVerified, true);
    assert.equal(changed.preservation.attachmentRowsVerified, true);
    assert.equal(changed.preservation.replacementFilesVerified, 0);
    assert.equal(
      sqlite("SELECT Z_ENT,count(*) FROM ZICCLOUDSYNCINGOBJECT GROUP BY Z_ENT ORDER BY Z_ENT;"),
      beforePopulation
    );
    assert.equal(
      sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTYPEUTI IS NOT NULL;"),
      "1"
    );
    afterAppend = text + changedText;
    checkDecoded(afterAppend);
    const after = read();
    assert.notEqual(after.revision, state.revision);
    assert.equal(after.revision, changed.revisionAfter);
    state = after;
  });
  const compose = {
    identifier: noteIdentifier,
    mode: "append",
    paragraphs: [
      { style: "heading", runs: [{ text: "Synthetic heading" }] },
      { style: "body", runs: [{ text: "Synthetic rich text", bold: true }] },
    ],
  };
  const plan = unchanged("ordinary-body compose: strict read-only capability", afterAppend, () =>
    call("compose_note", { ...compose, dryRun: true }, undefined, ["unsupported_note"])
  );
  report.ordinaryBodyCompose = {
    supported: plan.status !== "error",
    refusalCode: plan.status === "error" ? plan.code : null,
  };
  if (plan.status === "error") {
    test("strict c2 refuses unsupported ordinary native content layout without mutation", () => {
      unchanged("ordinary-body compose: strict apply refusal", afterAppend, () =>
        call(
          "compose_note",
          {
            ...compose,
            ifRevision: state.revision,
            ifPlanDigest: "c2:" + "0".repeat(64),
            ifAttachmentSnapshot: "a1:" + "0".repeat(64),
          },
          "COMPOSE",
          "unsupported_note"
        )
      );
    });
  } else {
    test("compose dry run returns digest and leaves revision unchanged", () => {
      assert.equal(plan.status, "planned");
      assert.match(plan.planDigest, /^c2:[0-9a-f]{64}$/);
      assert.equal(read().revision, state.revision);
      checkDecoded(afterAppend);
    });
    test("compose refuses missing/mismatched digest and preserves revision", () => {
      unchanged("compose: missing digest", afterAppend, () =>
        call(
          "compose_note",
          { ...compose, ifRevision: state.revision, ifAttachmentSnapshot: plan.attachmentSnapshot },
          "COMPOSE",
          "invalid_request"
        )
      );
      unchanged("compose: mismatched digest", afterAppend, () =>
        call(
          "compose_note",
          {
            ...compose,
            ifRevision: state.revision,
            ifPlanDigest: "c2:" + "0".repeat(64),
            ifAttachmentSnapshot: plan.attachmentSnapshot,
          },
          "COMPOSE",
          "plan_mismatch"
        )
      );
    });
    const prospectiveFilePath = join(root, "public-materialization-control.pdf");
    const prospectiveFile = Buffer.from(
      "%PDF-1.4\n% PUBLIC SYNTHETIC DIGEST REFUSAL CONTROL\n%%EOF\n"
    );
    writeFileSync(prospectiveFilePath, prospectiveFile, { mode: 0o600 });
    const fileCompose = {
      identifier: noteIdentifier,
      mode: "append",
      paragraphs: [
        { kind: "file", path: prospectiveFilePath, expectedSha256: hash(prospectiveFile) },
      ],
    };
    test("compose file plan and digest refusals leave exact objects, store and files unchanged", () => {
      const filePlan = unchanged("file compose: read-only plan", afterAppend, () =>
        call("compose_note", { ...fileCompose, dryRun: true })
      );
      assert.equal(filePlan.status, "planned");
      assert.equal(filePlan.committed, false);
      assert.equal(filePlan.objects.length, 1);
      unchanged("file compose: missing digest before materialization", afterAppend, () =>
        call(
          "compose_note",
          {
            ...fileCompose,
            ifRevision: filePlan.revisionBefore,
            ifAttachmentSnapshot: filePlan.attachmentSnapshot,
          },
          "COMPOSE",
          "invalid_request"
        )
      );
      unchanged("file compose: mismatched digest before materialization", afterAppend, () =>
        call(
          "compose_note",
          {
            ...fileCompose,
            ifRevision: filePlan.revisionBefore,
            ifPlanDigest: "c2:" + "0".repeat(64),
            ifAttachmentSnapshot: filePlan.attachmentSnapshot,
          },
          "COMPOSE",
          "plan_mismatch"
        )
      );
      assert.equal(hash(readSingleLinkFile(prospectiveFilePath)), hash(prospectiveFile));
      assert.equal(
        sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTYPEUTI IS NOT NULL;"),
        "1"
      );
    });
    const afterCompose = afterAppend + "\nSynthetic heading\nSynthetic rich text";
    test("real rich compose preserves prior text and stores exact heading and bold runs", () => {
      const changed = call(
        "compose_note",
        {
          ...compose,
          ifRevision: state.revision,
          ifPlanDigest: plan.planDigest,
          ifAttachmentSnapshot: plan.attachmentSnapshot,
        },
        "COMPOSE"
      );
      assert.equal(changed.committed, true);
      assert.equal(changed.verified, true);
      assert.notEqual(read().revision, state.revision);
      const { blocks } = checkDecoded(afterCompose);
      const added = blocks.blocks.filter((block) => block.start >= afterAppend.length + 1);
      assert.equal(added.length, 2, "exactly two composed paragraphs");
      const [heading, rich] = added;
      assert.deepEqual(
        [heading.text, heading.start, heading.length, heading.style, heading.styleType],
        ["Synthetic heading", afterAppend.length + 1, "Synthetic heading".length, "heading", 1]
      );
      assert.deepEqual(
        [rich.text, rich.start, rich.length, rich.style],
        [
          "Synthetic rich text",
          afterAppend.length + 1 + "Synthetic heading\n".length,
          "Synthetic rich text".length,
          "body",
        ]
      );
      for (const block of added) {
        assert.ok(block.runs.length > 0, "composed paragraph has stored attribute runs");
        assert.equal(
          block.runs.map((run) => run.text).join(""),
          block.text,
          "runs cover exactly the requested text"
        );
        let next = block.start;
        for (const run of block.runs) {
          assert.equal(run.start, next, "no missing or overlapping styled characters");
          assert.equal(run.length, run.text.length);
          if (block === rich)
            assert.equal(run.bold, true, "every rich-text character is stored bold");
          next += run.length;
        }
        assert.equal(next, block.start + block.length);
      }
    });
  }
  test("final store integrity and exact synthetic population remain intact", () => {
    assert.equal(sqlite("PRAGMA integrity_check;"), "ok");
    assert.equal(sqlite("SELECT count(*) FROM ZICNOTEDATA;"), "1");
    assert.equal(sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT;"), "7");
  });
  report.osVersion = command("/usr/bin/sw_vers", ["-productVersion"]).stdout.trim();
  report.completed = true;
  report.limitations = [
    "Copy-store evidence only; no live editor merge or cloud upload proof.",
    "Preference daemon access is denied; this does not prove persistent preference behavior.",
    "Native output remains local until reviewed; only the generated baseline is designed as public fixture data.",
    "p4 checks digest consistency with the loaded revision and request; no prior preview authentication is claimed.",
    "One hidden inline row is generated; token/tombstone/owned-row drift is exercised. No media bytes, table CRDT or body attachment glyphs are generated.",
    "Installed native content layout may refuse c2 before receipt comparison; unsupported layouts remain held and are reported separately.",
    "Prospective compose-file digest refusals prove no persistent materialization; a matching file apply is not attempted.",
    "The isolated user starts with empty Preferences and Caches infrastructure directories; cold Caches-directory initialization is not exercised.",
  ];
  persist("report.json", report);
  console.log(
    `Synthetic store checks passed (${report.tests.length}); private evidence: ${join(root, "report.json")}`
  );
} catch (error) {
  report.error = error.message;
  persist("report.json", report);
  console.error(
    `Synthetic store checks failed; private evidence: ${join(root, "report.json")}\n${error.message}`
  );
  process.exitCode = 1;
}
