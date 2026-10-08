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
  buildSyntheticAttributeFreePayload as buildSyntheticNotePayload,
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
  kind: "generated-attribute-free-compose-receipt-store",
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
    "--attribute-free-receipt-fixture",
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
    assert.equal(sqlite("SELECT count(*) FROM ZICCLOUDSTATE;"), "7");
    assert.equal(
      sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTYPEUTI IS NOT NULL;"),
      "0"
    );
    // The installed model stores ICInlineAttachment.typeUTI separately from
    // ICAttachment.typeUTI; keep the file-attachment zero check above exact.
    assert.equal(
      sqlite(
        "SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT=(SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME='ICInlineAttachment');"
      ),
      "1"
    );
    assert.equal(
      sqlite(
        "SELECT ZTYPEUTI1 FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT=(SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME='ICInlineAttachment');"
      ),
      "com.apple.notes.inlinetextattachment.dividerline"
    );
    assert.equal(hash(body()), hash(payload));
    assert.deepEqual([...readSingleLinkFile(store).subarray(18, 20)], [2, 2]);
    assert.ok(!initialStoreBytes.includes(Buffer.from(process.env.HOME ?? "/Users/")));
    assert.ok(!initialStoreBytes.includes(Buffer.from("group.com.apple.notes")));
  });
  // The generator has closed the fixed WAL baseline and no writer has run.
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
  test("attribute-free public CRDT has exact text length and one synthetic owner", () => {
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
    let result, failure;
    try {
      result = fn();
    } catch (error) {
      failure = error;
    }
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
      expectedOperationCompleted: !failure,
    });
    persist("report.json", report);
    if (failure) throw failure;
    return result;
  }
  const state = read();
  test("actual NotesShared opens fixed attribute-free public body", () => {
    assert.equal(state.bodyLengthUTF16, text.length);
    assert.equal(state.editable, true);
    assert.equal(state.bodyAvailable, true);
  });
  const compose = {
    identifier: noteIdentifier,
    mode: "append",
    paragraphs: [{ style: "body", runs: [{ text: "PUBLIC C2 RECEIPT CONTROL" }] }],
  };
  const plan = unchanged("attribute-free c2 read-only capability", text, () =>
    call("compose_note", { ...compose, dryRun: true }, undefined, ["unsupported_note"])
  );
  report.composeReceiptAvailable = plan.status !== "error";
  if (plan.status === "error") {
    test("strict c2 keeps unsupported decoded native layout held", () => {
      unchanged("attribute-free c2 strict apply refusal", text, () =>
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
    report.refusalCode = plan.code;
  } else {
    const checkPlan = (reviewed) => {
      assert.equal(reviewed.status, "planned");
      assert.equal(reviewed.committed, false);
      assert.equal(reviewed.revisionBefore, state.revision);
      assert.match(reviewed.planDigest, /^c2:[0-9a-f]{64}$/);
      assert.match(reviewed.attachmentSnapshot, /^a1:[0-9a-f]{64}$/);
      assert.equal(reviewed.frozenAttachments.inlineAttachments, 1);
      assert.equal(reviewed.frozenAttachments.attachments, 0);
      assert.equal(reviewed.frozenAttachments.filesHashed, 0);
      assert.equal(reviewed.frozenAttachments.evidenceComplete, true);
    };
    test("c2 plans fixed nonempty attribute-free target with nonempty a1", () => checkPlan(plan));
    const prospectiveFile = Buffer.from("%PDF-1.4\n% PUBLIC SYNTHETIC RECEIPT CONTROL\n%%EOF\n");
    const prospectiveFilePath = join(root, "public-prospective-attachment.pdf");
    writeFileSync(prospectiveFilePath, prospectiveFile, { mode: 0o600 });
    const fileCompose = {
      identifier: noteIdentifier,
      mode: "append",
      paragraphs: [
        { kind: "file", path: prospectiveFilePath, expectedSha256: hash(prospectiveFile) },
      ],
    };
    let filePlan;
    test("prospective file plan preserves all existing objects and files", () => {
      filePlan = unchanged("attribute-free file c2 plan before materialization", text, () =>
        call("compose_note", { ...fileCompose, dryRun: true })
      );
      checkPlan(filePlan);
      assert.equal(filePlan.objects.length, 1);
      assert.equal(filePlan.attachmentSnapshot, plan.attachmentSnapshot);
    });
    const applyFields = (fields, reviewed) => ({
      ...fields,
      ifRevision: reviewed.revisionBefore,
      ifPlanDigest: reviewed.planDigest,
      ifAttachmentSnapshot: reviewed.attachmentSnapshot,
    });
    for (const [kind, fields, reviewed] of [
      ["text", compose, plan],
      ["prospective file", fileCompose, filePlan],
    ]) {
      const exact = applyFields(fields, reviewed);
      const { ifPlanDigest, ...missingDigest } = exact;
      const { ifAttachmentSnapshot, ...missingReceipt } = exact;
      test(`c2 ${kind} missing and mismatched digest refuse exactly`, () => {
        unchanged(`${kind}: missing c2 digest`, text, () =>
          call("compose_note", missingDigest, "COMPOSE", "invalid_request")
        );
        unchanged(`${kind}: mismatched c2 digest`, text, () =>
          call(
            "compose_note",
            { ...exact, ifPlanDigest: "c2:" + "0".repeat(64) },
            "COMPOSE",
            "plan_mismatch"
          )
        );
      });
      test(`c2 ${kind} missing and mismatched a1 refuse exactly`, () => {
        unchanged(`${kind}: missing a1 receipt`, text, () =>
          call("compose_note", missingReceipt, "COMPOSE", "invalid_request")
        );
        unchanged(`${kind}: mismatched a1 receipt`, text, () =>
          call(
            "compose_note",
            { ...exact, ifAttachmentSnapshot: "a1:" + "0".repeat(64) },
            "COMPOSE",
            "attachment_snapshot_mismatch"
          )
        );
      });
    }
    let mutationInvocation = 0;
    const mutate = (mode) => {
      const before = read();
      const beforeBody = hash(body());
      const result = sandbox(generator, [
        store,
        payloadPath,
        noteIdentifier,
        replicaIdentifier,
        mode,
      ]);
      const name = `generated-mutation-${++mutationInvocation}`;
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
      checkDecoded(text);
    };
    test("c2 stale nonempty a1 blocks text and prospective file before materialization", () => {
      const beforeBody = hash(body());
      const beforeFile = hash(readSingleLinkFile(prospectiveFilePath));
      mutate("--inline-token");
      const fresh = unchanged("attribute-free c2 fresh drift plan", text, () =>
        call("compose_note", { ...fileCompose, dryRun: true })
      );
      checkPlan(fresh);
      assert.notEqual(fresh.attachmentSnapshot, filePlan.attachmentSnapshot);
      assert.notEqual(fresh.planDigest, filePlan.planDigest);
      assert.equal(hash(body()), beforeBody);
      assert.equal(hash(readSingleLinkFile(prospectiveFilePath)), beforeFile);
      for (const [kind, fields, reviewed] of [
        ["text", compose, plan],
        ["prospective file", fileCompose, filePlan],
      ])
        unchanged(`${kind}: stale a1 before native materialization`, text, () =>
          call(
            "compose_note",
            applyFields(fields, reviewed),
            "COMPOSE",
            "attachment_snapshot_mismatch"
          )
        );
      report.attachmentDrift = {
        revisionUnchanged: true,
        bodyUnchanged: true,
        fileBytesUnchanged: true,
        requestUnchanged: true,
        priorReceiptSha256: hash(filePlan.attachmentSnapshot),
        freshReceiptSha256: hash(fresh.attachmentSnapshot),
        staleTextAndFileRefused: true,
      };
      mutate("--inline-restore");
      const restored = unchanged("attribute-free c2 restored fixed row plan", text, () =>
        call("compose_note", { ...fileCompose, dryRun: true })
      );
      assert.equal(restored.attachmentSnapshot, filePlan.attachmentSnapshot);
      assert.equal(restored.planDigest, filePlan.planDigest);
    });
  }
  test("final attribute-free fixture integrity and population", () => {
    assert.equal(sqlite("PRAGMA integrity_check;"), "ok");
    assert.equal(sqlite("SELECT count(*) FROM ZICNOTEDATA;"), "1");
    assert.equal(sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT;"), "7");
    assert.equal(sqlite("SELECT count(*) FROM ZICCLOUDSTATE;"), "7");
    assert.equal(
      sqlite("SELECT count(*) FROM ZICCLOUDSYNCINGOBJECT WHERE ZTYPEUTI IS NOT NULL;"),
      "0"
    );
    checkDecoded(text);
  });
  report.completed = true;
  report.limitations = [
    "Fixed attribute-free public target only; ordinary native styled-body compatibility remains held.",
    "No live store, editor, preferences or cloud proof and no prior preview authentication claim.",
    "No compose no-op grammar exists; exact no-op receipt proof belongs to separate p4 fixture.",
    "Only prospective file plans/refusals are tested; no matching file apply or existing media file is generated.",
  ];
  persist("report.json", report);
  console.log(
    `Bounded c2 checks completed (${report.tests.length}); receipt coverage: ${report.composeReceiptAvailable}; private evidence: ${join(root, "report.json")}`
  );
} catch (error) {
  report.error = error.message;
  persist("report.json", report);
  console.error(
    `Bounded c2 checks failed after ${report.tests.length} checks; details remain private: ${join(root, "report.json")}`
  );
  process.exitCode = 1;
}
