import { dirname, relative, resolve } from "node:path";
import { sha256Hex, type PrivateHelperDeps } from "./privateHelper.js";

/** Bind the writer and every quoted local include; system framework headers are external. */
export function writerSourceSha256(
  deps: Pick<PrivateHelperDeps, "sourcePath" | "readFile" | "exists">
): string {
  const root = dirname(resolve(deps.sourcePath));
  const closure = new Map<string, string>();
  const visit = (path: string): void => {
    const name = relative(root, path);
    if (name.startsWith("../") || name === "..")
      throw new Error("Writer local include escapes its source directory");
    if (closure.has(name)) return;
    if (!deps.exists(path)) throw new Error(`Packaged writer source is missing: ${path}`);
    const source = deps.readFile(path);
    closure.set(name, sha256Hex(source));
    const directives = source
      .toString("utf8")
      .replace(/\\\r?\n/g, "")
      .replace(/\/\*[\s\S]*?\*\//g, " ");
    for (const directive of directives.matchAll(/^\s*#\s*(?:include|import)\b\s*([^\n]+)/gm)) {
      const local = directive[1].match(/^"([^"\n]+)"\s*(?:\/\/.*)?$/);
      if (local) visit(resolve(dirname(path), local[1]));
      else if (!/^<[^>\n]+>\s*(?:\/\/.*)?$/.test(directive[1]))
        throw new Error("Writer includes must name a literal local or system header");
    }
  };
  visit(resolve(deps.sourcePath));
  // Keep the legacy checksum for single-source fixture writers only. Every
  // packaged writer now includes its substrates and uses the closure format.
  if (closure.size === 1) return closure.values().next().value as string;
  return sha256Hex(
    JSON.stringify({
      schema: "writer-source-closure-v1",
      files: [...closure.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
    })
  );
}
