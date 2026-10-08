import { describe, expect, it } from "vitest";
import { sha256Hex } from "./privateHelper.js";
import { writerSourceSha256 } from "./privateWriterSources.js";

function fixture(files: Record<string, string>) {
  return {
    sourcePath: "/packaged/writer.m",
    exists: (path: string) => path in files,
    readFile: (path: string) => Buffer.from(files[path]),
  };
}
describe("writer source closure checksum", () => {
  const files = {
    "/packaged/writer.m": '#include "attachment-evidence.h"\n#include "content-preservation.h"\n',
    "/packaged/attachment-evidence.h": "// bytes",
    "/packaged/content-preservation.h": "// attrs",
  };
  it("binds both independently factored support headers", () => {
    const original = writerSourceSha256(fixture(files));
    for (const path of Object.keys(files))
      expect(writerSourceSha256(fixture({ ...files, [path]: files[path] + "changed" }))).not.toBe(
        original
      );
  });
  it("binds recursive local includes and refuses a missing dependency", () => {
    const nested = {
      ...files,
      "/packaged/attachment-evidence.h": '#include "nested.h"',
      "/packaged/nested.h": "one",
    };
    expect(writerSourceSha256(fixture(nested))).not.toBe(
      writerSourceSha256(fixture({ ...nested, "/packaged/nested.h": "two" }))
    );
    expect(() =>
      writerSourceSha256(
        fixture({ ...nested, "/packaged/nested.h": undefined } as unknown as Record<string, string>)
      )
    ).toThrow();
  });
  it("refuses includes outside the packaged directory", () => {
    expect(() =>
      writerSourceSha256(fixture({ "/packaged/writer.m": '#include "../escape.h"' }))
    ).toThrow(/escapes/);
  });
  it("refuses a macro include whose source closure cannot be established", () => {
    expect(() =>
      writerSourceSha256(fixture({ "/packaged/writer.m": "#include SUPPORT_HEADER" }))
    ).toThrow(/literal/);
  });
  it.each(['#include"support.h"', '#include/**/"support.h"', '#include \\\n"support.h"'])(
    "binds valid include formatting %s",
    (source) => {
      const original = writerSourceSha256(
        fixture({ "/packaged/writer.m": source, "/packaged/support.h": "one" })
      );
      expect(
        writerSourceSha256(fixture({ "/packaged/writer.m": source, "/packaged/support.h": "two" }))
      ).not.toBe(original);
    }
  );
  it("preserves checksums of single-source stand-in fixtures", () => {
    expect(writerSourceSha256(fixture({ "/packaged/writer.m": "// stand-in" }))).toBe(
      sha256Hex("// stand-in")
    );
  });
});
