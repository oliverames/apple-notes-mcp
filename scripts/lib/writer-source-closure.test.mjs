import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { test } from "node:test";
import { transformSync } from "esbuild";
import { writerSourceClosure } from "./writer-source-closure.mjs";
const sha256Hex = (bytes) => createHash("sha256").update(bytes).digest("hex");
// Extract only the pure exported function; no production service/runtime imports.
const source = readFileSync(
  new URL("../../src/services/privateWriterSources.ts", import.meta.url),
  "utf8"
);
const code = transformSync(source.slice(source.indexOf("export function writerSourceSha256")), {
  loader: "ts",
  format: "cjs",
}).code;
const module = { exports: {} };
new Function("module", "exports", "dirname", "relative", "resolve", "sha256Hex", code)(
  module,
  module.exports,
  dirname,
  relative,
  resolve,
  sha256Hex
);
const productionHash = module.exports.writerSourceSha256;

test("report closure exactly matches the pure production function for packaged writer and all local headers", () => {
  const sourcePath = new URL(
    "../../native/private-helper/apple-notes-private-writer.m",
    import.meta.url
  ).pathname;
  const actual = writerSourceClosure(sourcePath);
  assert.equal(
    actual.sha256,
    productionHash({
      sourcePath,
      readFile: readFileSync,
      exists: (p) => {
        try {
          readFileSync(p);
          return true;
        } catch {
          return false;
        }
      },
    })
  );
  assert.deepEqual(
    actual.files.map(([name]) => name),
    [
      "apple-notes-private-writer.m",
      "attachment-evidence.h",
      "content-preservation.h",
      "legacy-attribute-projection.h",
      "native-attribute-layouts.h",
      "public-font-preservation.h",
    ]
  );
  assert.equal(
    actual.sha256,
    sha256Hex(JSON.stringify({ schema: actual.schema, files: actual.files }))
  );
});
test("nested headers, comments and line splices match; missing, escaping and macro includes refuse", () => {
  for (const main of [
    '#include "sub/a.h"\n',
    '# import /*ignored*/ "sub/a.h"\n',
    '#inc\\\nlude "sub/a.h"\n',
    '// #include "missing"\n#import <Foundation/Foundation.h>\n',
  ]) {
    const files = new Map([
      ["/fixture/main.m", Buffer.from(main)],
      ["/fixture/sub/a.h", Buffer.from('#include "../b.h"\n')],
      ["/fixture/b.h", Buffer.from("// leaf")],
    ]);
    const deps = {
      sourcePath: "/fixture/main.m",
      readFile: (p) => files.get(p),
      exists: (p) => files.has(p),
    };
    assert.equal(
      writerSourceClosure(deps.sourcePath, deps.readFile, deps.exists).sha256,
      productionHash(deps)
    );
  }
  for (const main of [
    '#include "missing.h"',
    '#include "../outside.h"',
    "#include MACRO",
    '#include "bad name.h"',
  ]) {
    const deps = {
      sourcePath: "/fixture/main.m",
      readFile: () => Buffer.from(main),
      exists: (p) => p === "/fixture/main.m",
    };
    assert.throws(() => writerSourceClosure(deps.sourcePath, deps.readFile, deps.exists));
    assert.throws(() => productionHash(deps));
  }
});
