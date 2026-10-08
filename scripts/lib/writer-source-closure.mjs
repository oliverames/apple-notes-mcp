// Read-only provenance for fixture reports. No writer/service module is loaded.
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

/** Mirrors the production writerSourceSha256 literal-include closure contract. */
export function writerSourceClosure(sourcePath, readFile = readFileSync, exists = existsSync) {
  const root = dirname(resolve(sourcePath));
  const closure = new Map();
  const visit = (path) => {
    const name = relative(root, path);
    if (name.startsWith("../") || name === "..")
      throw new Error("Writer local include escapes its source directory");
    if (closure.has(name)) return;
    if (!exists(path)) throw new Error(`Packaged writer source is missing: ${path}`);
    const source = readFile(path);
    closure.set(name, sha256(source));
    const directives = source
      .toString("utf8")
      .replace(/\\\r?\n/g, "")
      .replace(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, (token) =>
        token.startsWith("/*") || token.startsWith("//") ? token.replace(/[^\n]/g, " ") : token
      );
    for (const directive of directives.matchAll(/^\s*#\s*(?:include|import)\b\s*([^\n]+)/gm)) {
      const local = directive[1].match(/^"([^"\n]+)"\s*(?:\/\/.*)?$/);
      if (local) {
        if (!/^[a-zA-Z0-9_./-]+$/.test(local[1]))
          throw new Error("Writer local include names must use plain relative paths");
        visit(resolve(dirname(path), local[1]));
      } else if (!/^<[^>\n]+>\s*(?:\/\/.*)?$/.test(directive[1]))
        throw new Error("Writer includes must name a literal local or system header");
    }
  };
  visit(resolve(sourcePath));
  const files = [...closure.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  const document = { schema: "writer-source-closure-v1", files };
  return {
    ...document,
    sha256: files.length === 1 ? files[0][1] : sha256(JSON.stringify(document)),
  };
}
