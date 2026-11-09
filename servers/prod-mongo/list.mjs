// What prod-mongo's backups root holds, and the retention rule: the list-backups tool's answer and
// the line backup's answer ends with. It reads only the root: no database, no credential.
//
//   kept                     5: the newest verified dumps the rule keeps
//   listRoot(real)           { dumps, others, bytes }: each folder named by a stamp with a readable
//                            manifest.json, newest first ({ stamp, manifest, verified, bytes, drills,
//                            newestDrill, rehearsals, undos, diffs }), every other entry by name
//                            ({ name, bytes, kind: "unfinished" | "writing" | "other" }), and the
//                            bytes of every file under the root
//   retentionLine(dumps)     how many dumps the root holds, their size, and the ones past the rule
//   listing({ real, shownRoot, note, missing })   list-backups' answer
//   writing                  the partial folders a backup of this server is writing now, which the
//                            listing names apart from the ones a killed server left
//
// The toolkit never deletes a dump: the ones past the rule are named for Daniel to delete by hand.
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { count, humanBytes } from "./dump.mjs";
import { partialPattern, stampPattern } from "./root.mjs";

export const kept = 5;
export const writing = new Set();

const plural = (n, word) => `${count(n)} ${word}${n === 1 ? "" : "s"}`;

// The bytes of every file under `path` (itself when a file), never following a symlink.
function bytesOf(path) {
  let stat;
  try {
    stat = lstatSync(path);
  } catch {
    return 0;
  }
  if (stat.isFile()) return stat.size;
  if (!stat.isDirectory()) return 0;
  let bytes = 0;
  for (const name of entriesOf(path)) bytes += bytesOf(join(path, name));
  return bytes;
}

function entriesOf(dir) {
  try {
    return readdirSync(dir).sort();
  } catch {
    return [];
  }
}

// The entries of a dump's subfolder that are of one kind: the drills' and diffs' JSON files, the
// rehearsals' and undos' folders.
function kindOf(dir, want) {
  return entriesOf(dir).filter((name) => {
    try {
      const stat = lstatSync(join(dir, name));
      return want === "file" ? stat.isFile() && name.endsWith(".json") : stat.isDirectory();
    } catch {
      return false;
    }
  });
}

function manifestOf(folder) {
  try {
    const file = join(folder, "manifest.json");
    if (!lstatSync(folder).isDirectory() || !lstatSync(file).isFile()) return undefined;
    const manifest = JSON.parse(readFileSync(file, "utf8"));
    return manifest && typeof manifest === "object" && !Array.isArray(manifest) ? manifest : undefined;
  } catch {
    return undefined;
  }
}

// A drill's verdict, from drills/<at>.json's `verdict`: PASS or FAIL.
function verdictOf(file) {
  try {
    const { verdict } = JSON.parse(readFileSync(file, "utf8"));
    return ["PASS", "FAIL"].includes(verdict) ? verdict : "unreadable";
  } catch {
    return "unreadable";
  }
}

export function listRoot(real) {
  const dumps = [];
  const others = [];
  let bytes = 0;
  for (const name of entriesOf(real)) {
    const path = join(real, name);
    const size = bytesOf(path);
    bytes += size;
    const manifest = stampPattern.test(name) ? manifestOf(path) : undefined;
    if (!manifest) {
      const kind = partialPattern.test(name) ? (writing.has(path) ? "writing" : "unfinished") : "other";
      others.push({ name, bytes: size, kind });
      continue;
    }
    const drills = kindOf(join(path, "drills"), "file");
    dumps.push({
      stamp: name,
      manifest,
      verified: manifest.verified === true,
      bytes: size,
      drills: drills.length,
      newestDrill: drills.length ? verdictOf(join(path, "drills", drills.at(-1))) : undefined,
      rehearsals: kindOf(join(path, "rehearsals"), "dir").length,
      undos: kindOf(join(path, "undo"), "dir").length,
      diffs: kindOf(join(path, "diffs"), "file").length,
    });
  }
  dumps.sort((a, b) => (a.stamp < b.stamp ? 1 : -1));
  return { dumps, others, bytes };
}

// The newest `kept` verified dumps are kept; every other dump, an unverified one included, is
// past the rule.
export function retentionLine(dumps) {
  const keep = new Set(dumps.filter(({ verified }) => verified).slice(0, kept).map(({ stamp }) => stamp));
  const past = dumps.filter(({ stamp }) => !keep.has(stamp));
  const size = humanBytes(dumps.reduce((sum, { bytes }) => sum + bytes, 0));
  if (!dumps.length) return `The folder holds no dumps; the newest ${kept} are kept.`;
  const holds = `The folder holds ${plural(dumps.length, "dump")} (${size}); the newest ${kept} are kept`;
  if (!past.length) return `${holds}, none is past that.`;
  const named = past.map(({ stamp, verified }) => (verified ? stamp : `${stamp} (not verified)`)).join(", ");
  return `${holds}, so ${count(past.length)} ${past.length === 1 ? "is" : "are"} past that, for Daniel to delete by hand: ${named}.`;
}

function kinds(totals = {}) {
  const collections = Number(totals.collections ?? 0);
  const views = Number(totals.views ?? 0);
  return [plural(collections, "collection"), ...(views ? [plural(views, "view")] : [])].join(" and ");
}

function dumpLine({ stamp, manifest, verified, bytes, drills, newestDrill, rehearsals, undos, diffs }) {
  const documents = Number(manifest.totals?.documents ?? 0);
  const drilled = drills ? `${plural(drills, "drill")} (newest ${newestDrill})` : "0 drills";
  const derived = [drilled, plural(rehearsals, "rehearsal"), plural(undos, "undo"), plural(diffs, "diff")].join(", ");
  return `- ${stamp}: ${kinds(manifest.totals)}, ${plural(documents, "document")}, ${humanBytes(bytes)}, ${verified ? "verified" : "not verified"}; ${derived}`;
}

const otherKinds = { other: "not taken by this toolkit", unfinished: "left unfinished", writing: "being written by the backup running now" };

export function listing({ real, shownRoot, note, missing }) {
  if (missing) return [`${shownRoot} does not exist yet, so it holds no dumps.`, retentionLine([])].join("\n");
  const { dumps, others, bytes } = listRoot(real);
  const lines = [];
  if (dumps.length) {
    lines.push(`${shownRoot} holds ${plural(dumps.length, "dump")} taken by this toolkit, newest first:`);
    for (const dump of dumps) lines.push(dumpLine(dump));
  } else {
    lines.push(`${shownRoot} holds no dump taken by this toolkit.`);
  }
  if (others.length) {
    lines.push(`${others.length === 1 ? "1 other entry" : `${count(others.length)} other entries`}:`);
    for (const { name, bytes: size, kind } of others) lines.push(`- ${name}: ${humanBytes(size)}, ${otherKinds[kind]}`);
  }
  lines.push(`In all, ${humanBytes(bytes)}.`);
  if (note) lines.push(note);
  lines.push(retentionLine(dumps));
  return lines.join("\n");
}
