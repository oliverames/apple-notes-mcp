import fs from "node:fs";
import path from "node:path";

// Normal mode: write package.json's version into every plugin manifest.
// --check mode: write NOTHING; exit 0 silently when every manifest already
// matches, exit 1 listing the mismatched files (CI runs this so a manifest
// can never drift behind a version bump).
const checkMode = process.argv.includes("--check");

const root = process.cwd();
const packageJson = readJson("package.json");
const version = packageJson.version;
const mismatches = [];

updateJson(".claude-plugin/plugin.json", (data) => {
  data.version = version;
});

updateJson("codex/.codex-plugin/plugin.json", (data) => {
  data.version = version;
});

updateJson(".claude-plugin/marketplace.json", (data) => {
  for (const plugin of data.plugins ?? []) {
    if (plugin.name === "apple-notes") {
      plugin.version = version;
    }
  }
});

updateJson(".agents/plugins/marketplace.json", (data) => {
  for (const plugin of data.plugins ?? []) {
    if (plugin.name === "apple-notes") {
      plugin.version = version;
    }
  }
});

updateJson(".antigravity-plugin/plugin.json", (data) => {
  data.version = version;
});

updateJson(".antigravity-plugin/marketplace.json", (data) => {
  for (const plugin of data.plugins ?? []) {
    if (plugin.name === "apple-notes") {
      plugin.version = version;
    }
  }
});

if (checkMode && mismatches.length > 0) {
  console.error(
    `Plugin manifest versions do not match package.json (${version}):`,
  );
  for (const file of mismatches) {
    console.error(`  ${file}`);
  }
  console.error("Fix: node scripts/sync-plugin-version.mjs");
  process.exit(1);
}

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(root, relativePath), "utf8"));
}

function updateJson(relativePath, update) {
  const fullPath = path.join(root, relativePath);
  const data = readJson(relativePath);
  const before = JSON.stringify(data, null, 2);
  update(data);
  const after = JSON.stringify(data, null, 2);
  if (checkMode) {
    if (before !== after) {
      mismatches.push(relativePath);
    }
    return;
  }
  fs.writeFileSync(fullPath, `${after}\n`);
}
