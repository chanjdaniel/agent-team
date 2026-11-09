// prod-mongo's backup tool: one verified mongodump of the database into <root>/<UTC stamp>/.
//
//   await takeBackup({ MongoClient, value, database, root, mongodump, scrubbed, shown, progress })
//                            the answer's text; throws a Refusal (refusal.mjs) when the backup was
//                            refused or failed
//   roomRefusal(free, dataSize)   why a file system with `free` bytes has no room for a dump of a
//                            database of `dataSize` bytes, or nothing
//   stampOf(date)            the folder name of a backup started at `date`: 2026-11-08T142305Z
//
// The steps: check the root against every rule before any connection (root.mjs's checkRoot,
// which makes it with mode 0700, or sets a looser one to 0700), read the server's version and
// dbStats and check the room, list the collections and count each one's documents (before),
// dump into <root>/.<stamp>.partial/dump through a FIFO in that 0700 directory that carries the
// connection string to `mongodump --config` and is gone once mongodump has read it, count again
// (after), count the dump's own documents and read its index names, judge each collection, then
// write manifest.json and rename the folder to <root>/<stamp>/; the answer ends with the
// retention line (list.mjs). On any failure the partial folder, which this call made, is
// removed. mongodump's own output never reaches an answer: only its exit and its last stderr
// line, through `scrubbed`.
import { spawnSync } from "node:child_process";
import { closeSync, constants, existsSync, mkdirSync, openSync, readdirSync, renameSync, rmSync, statSync, statfsSync, unlinkSync, writeFileSync, writeSync } from "node:fs";
import { join } from "node:path";
import { childEnv, lastLine, run } from "./children.mjs";
import { count, duration, humanBytes, readDump } from "./dump.mjs";
import { listRoot, retentionLine, writing } from "./list.mjs";
import { Refusal } from "./refusal.mjs";
import { checkRoot } from "./root.mjs";

const mongodumpTimeoutMs = 20 * 60_000;
const fifoOpenTimeoutMs = 30_000;
const gib = 1024 ** 3;

export function stampOf(date) {
  return `${date.toISOString().slice(0, 19).replaceAll(":", "")}Z`;
}

export function roomRefusal(free, dataSize) {
  const need = gib + 2 * dataSize;
  if (free >= need) return undefined;
  return `the backups folder's disk has ${humanBytes(free)} free, less than the ${humanBytes(need)} a dump needs (1 GiB plus twice the database's ${humanBytes(dataSize)} of data)`;
}

// mongodump dumps every collection but those under system., except system.js.
const dumped = (name) => !name.startsWith("system.") || name === "system.js";

export async function takeBackup({ MongoClient, value, database, root, mongodump, scrubbed, shown, progress }) {
  const started = new Date();
  const stamp = stampOf(started);

  progress("checking the backups folder");
  const { real, note } = checkRoot(root, { create: true, shown });
  const folder = join(real, stamp);
  const partial = join(real, `.${stamp}.partial`);
  const shownFolder = `${shown(root)}/${stamp}`;
  if (existsSync(folder) || existsSync(partial)) throw new Refusal(`${shownFolder} already exists: ask again in a second`);

  const client = new MongoClient(value, { serverSelectionTimeoutMS: 20_000, appName: "prod-mongo" });
  const failure = (error) => new Refusal(driverReason(error, scrubbed));
  try {
    progress("reading the database's size");
    let serverVersion;
    let stats;
    try {
      await client.connect();
      serverVersion = (await client.db(database).admin().command({ buildInfo: 1 })).version;
      stats = await client.db(database).command({ dbStats: 1 });
    } catch (error) {
      throw failure(error);
    }
    const { bavail, bsize } = statfsSync(real);
    const room = roomRefusal(Number(bavail) * Number(bsize), Number(stats.dataSize ?? 0));
    if (room) throw new Refusal(room);

    progress("counting each collection");
    let listed;
    let before;
    try {
      listed = (await client.db(database).listCollections({}, { authorizedCollections: true }).toArray())
        .filter(({ name }) => dumped(name))
        .map(({ name, type }) => ({ name, type: type === "view" ? "view" : "collection" }))
        .sort((a, b) => a.name.localeCompare(b.name));
      before = await countAll(client, database, listed);
    } catch (error) {
      throw failure(error);
    }

    mkdirSync(partial, { mode: 0o700 });
    writing.add(partial);
    try {
      progress("dumping");
      await dump({ value, database, partial, mongodump, scrubbed });

      progress("counting each collection again");
      let after;
      try {
        after = await countAll(client, database, listed);
      } catch (error) {
        throw failure(error);
      }

      progress("checking the dump");
      const inDump = await readDump(join(partial, "dump", database));
      const collections = judge(listed, before, after, inDump);
      const bad = collections.filter(({ judgement }) => !["match", "changed"].includes(judgement));
      if (bad.length) {
        throw new Refusal(`the dump does not match the database, so it was removed: ${bad.map(described).join("; ")}`);
      }

      const ended = new Date();
      const documents = collections.reduce((sum, { dumped: n }) => sum + (n ?? 0), 0);
      const manifest = {
        database,
        started: started.toISOString(),
        ended: ended.toISOString(),
        mongodump: mongodump.version,
        server: serverVersion,
        collections,
        totals: {
          collections: collections.filter(({ type }) => type === "collection").length,
          views: collections.filter(({ type }) => type === "view").length,
          documents,
          bytes: 0,
        },
        verified: true,
      };
      writeFileSync(join(partial, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
      manifest.totals.bytes = bytesUnder(partial);
      writeFileSync(join(partial, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 });
      renameSync(partial, folder);
      return [answer({ manifest, folder: shownFolder, took: ended - started }), ...(note ? [note] : []), retentionLine(listRoot(real).dumps)].join("\n");
    } catch (error) {
      rmSync(partial, { recursive: true, force: true });
      throw error;
    } finally {
      writing.delete(partial);
    }
  } finally {
    await client.close().catch(() => {});
  }
}

async function countAll(client, database, listed) {
  const counts = new Map();
  for (const { name, type } of listed) {
    if (type === "collection") counts.set(name, await client.db(database).collection(name).countDocuments({}));
  }
  return counts;
}

// mongodump --config=<fifo>: the connection string goes into the FIFO as one YAML line once
// mongodump has opened it, and the FIFO is unlinked before mongodump has done anything else.
async function dump({ value, database, partial, mongodump, scrubbed }) {
  const fifo = join(partial, "config.fifo");
  const made = spawnSync("mkfifo", ["-m", "600", fifo], { env: childEnv(), stdio: ["ignore", "ignore", "pipe"], encoding: "utf8" });
  if (made.error || made.status !== 0) throw new Refusal(`mkfifo failed: ${scrubbed(lastLine(made.stderr) || made.error?.message)}`);
  const args = [`--config=${fifo}`, "--db", database, "--gzip", "--out", join(partial, "dump"), "--quiet"];
  let fed;
  let result;
  try {
    result = await run(mongodump.command, args, {
      timeoutMs: mongodumpTimeoutMs,
      onSpawn: (child) => {
        fed = feed(fifo, `uri: '${value.replaceAll("'", "''")}'\n`, child).finally(() => rmSync(fifo, { force: true }));
        fed.catch(() => child.kill("SIGKILL"));
      },
    });
  } catch (error) {
    throw new Refusal(`mongodump could not start: ${scrubbed(error.message)}`);
  } finally {
    rmSync(fifo, { force: true });
  }
  try {
    await fed;
  } catch (error) {
    throw new Refusal(`mongodump never read its config: ${scrubbed(error.message)}`);
  }
  if (result.timedOut) throw new Refusal(`mongodump did not finish in ${duration(mongodumpTimeoutMs)}, so it was killed and the partial dump removed`);
  if (result.code !== 0) {
    const why = scrubbed(lastLine(result.stderr));
    throw new Refusal(`mongodump ${result.signal ? `was killed (${result.signal})` : `exited ${result.code}`}${why ? `: ${why}` : ""}, so the partial dump was removed`);
  }
}

// Open the FIFO for writing without blocking, which fails with ENXIO until mongodump opens its
// end: retry every 10 ms until it does, it exits, or 30 seconds pass.
async function feed(fifo, text, child) {
  const start = Date.now();
  for (;;) {
    let fd;
    try {
      fd = openSync(fifo, constants.O_WRONLY | constants.O_NONBLOCK);
    } catch (error) {
      if (error.code !== "ENXIO") throw error;
      if (child.pid === undefined || child.exitCode !== null || child.signalCode !== null) throw new Error("mongodump exited first");
      if (Date.now() - start > fifoOpenTimeoutMs) throw new Error(`not opened in ${duration(fifoOpenTimeoutMs)}`);
      await new Promise((resolve) => setTimeout(resolve, 10));
      continue;
    }
    try {
      writeSync(fd, text);
    } finally {
      closeSync(fd);
      unlinkSync(fifo);
    }
    return;
  }
}

// Each listed collection's judgement against its counts before, after and in the dump, then any
// collection the dump holds that was not listed.
function judge(listed, before, after, inDump) {
  const collections = listed.map(({ name, type }) => {
    const dumpedOne = inDump.get(name);
    const entry = {
      name,
      type,
      before: before.get(name) ?? null,
      after: after.get(name) ?? null,
      dumped: dumpedOne?.documents ?? null,
      judgement: "match",
      bytes: dumpedOne?.bytes ?? 0,
      indexes: dumpedOne?.indexes ?? [],
    };
    if (!dumpedOne || (type === "collection" && dumpedOne.documents === undefined)) entry.judgement = "missing";
    else if (type === "view") entry.judgement = "match";
    else if (entry.before !== entry.after) entry.judgement = "changed";
    else if (entry.dumped !== entry.before) entry.judgement = "mismatch";
    return entry;
  });
  for (const [name, found] of inDump) {
    if (listed.some((entry) => entry.name === name)) continue;
    collections.push({ name, type: found.type, before: null, after: null, dumped: found.documents, judgement: "extra", bytes: found.bytes, indexes: found.indexes });
  }
  return collections;
}

function described({ name, before, after, dumped: n, judgement }) {
  if (judgement === "missing") return `${name} is not in the dump (${count(before ?? 0)} in the database)`;
  if (judgement === "extra") return `${name} is in the dump but was not listed (${count(n ?? 0)} in the dump)`;
  return `${name} has ${count(n ?? 0)} in the dump, ${count(before)} in the database before and after`;
}

function bytesUnder(dir) {
  let bytes = 0;
  for (const entry of readdirSync(dir, { withFileTypes: true, recursive: true })) {
    if (entry.isFile()) bytes += statSync(join(entry.parentPath, entry.name)).size;
  }
  return bytes;
}

function answer({ manifest, folder, took }) {
  const { collections, totals } = manifest;
  const changed = collections.filter(({ judgement }) => judgement === "changed");
  const plural = (n, word) => `${count(n)} ${word}${n === 1 ? "" : "s"}`;
  const kinds = [plural(totals.collections, "collection"), ...(totals.views ? [plural(totals.views, "view")] : [])].join(" and ");
  const lines = [
    `Backup taken: ${folder} (${humanBytes(totals.bytes)} on disk, ${duration(took)}), mongodump ${manifest.mongodump}`,
    `${kinds}, ${plural(totals.documents, "document")}, each matching the database's count${changed.length ? `, but ${count(changed.length)} changed during the dump` : ""}:`,
  ];
  for (const { name, type, before, after, dumped: n, judgement } of collections) {
    if (type === "view") lines.push(`- ${name}: a view, its definition only`);
    else if (judgement === "changed") lines.push(`- ${name}: ${plural(n, "document")}, changed during the dump (${count(before)} before, ${count(after)} after)`);
    else lines.push(`- ${name}: ${plural(n, "document")}`);
  }
  return lines.join("\n");
}

// A driver error as one line: never its text when it may name the host.
function driverReason(error, scrubbed) {
  if (error?.name === "MongoServerSelectionError" || error?.name === "MongoNetworkError") return "could not reach the database";
  if (error?.code === 18 || /authentication failed/i.test(error?.message ?? "")) return "the database refused the read user's credentials";
  return `the database refused a read: ${scrubbed(error?.message)}`;
}
