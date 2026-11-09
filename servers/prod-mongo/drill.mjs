// prod-mongo's restore drill: proves a dump restores, by restoring it into a throwaway local
// MongoDB (throwaway.mjs) and comparing every collection with the dump's manifest.
//
//   await restoreDrill({ argv, database, root })
//                            the body of toolkits/prod-mongo/scripts/restore-drill.mjs: prints one
//                            JSON object on stdout (with --text, drillAnswer's text instead) and
//                            exits 0 on PASS, 1 on FAIL, a refusal or a failure, and 128 plus
//                            the signal's number when stopped by SIGINT, SIGTERM or SIGHUP
//   await drillTool({ input, root, shown, scrubbed, progress })
//                            the restore-drill tool: runs that script through the server's own
//                            checkout's bin/team-heavy, and answers { text, isError }
//   drillAnswer(result)      the tool's answer to the script's JSON: { text, isError }
//   restoreLimit             512 MiB: the largest dump (its manifest's total bytes) a drill takes,
//                            since tmpfs in the throwaway's 2 GiB cap could not hold more
//
// The script takes exactly one argument, a backup's stamp (and --text), never a path or a
// connection string: it reads no credential, so it cannot reach production. Before Docker is
// touched it checks the root (root.mjs's rules), the stamp (a verified dump directly under the
// root), the dump's database and size, and that mongorestore and the driver are installed; each
// failure there is a refusal. Then it removes what an earlier run left past its expiry, starts the
// throwaway, restores with `mongorestore --config=<fifo> --nsInclude '<database>.*' --gzip --dir
// <folder>/dump`, the throwaway's connection string going through a FIFO in the dump's 0700
// drills/ folder, compares each collection's document count and index names (and each view's
// being there) with the manifest, writes drills/<at>.json (mode 0600, `verdict` PASS or FAIL, the
// name the drill's start stamp) and removes the throwaway, on every path: at the end, on an error,
// and on SIGINT, SIGTERM and SIGHUP. A Docker failure is no verdict on the dump, so it writes no
// record. mongorestore's own output never reaches the JSON but its last line on a failure, scrubbed.
// The JSON forms: { refused }; { failed, stamp, folder, container, removed, cleanup }; and
// { verdict, stamp, folder, at, record, seconds, mongorestore, container, collections,
// restoreError?, removed, cleanup }, every path written from ~/.
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, writeFileSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { stampOf } from "./backup.mjs";
import { childEnv, lastLine, run, runWithConfig, scrubber, yamlConfig } from "./children.mjs";
import { count, duration, humanBytes } from "./dump.mjs";
import { listRoot } from "./list.mjs";
import { Refusal } from "./refusal.mjs";
import { checkRoot, dumpByStamp } from "./root.mjs";
import { removeExpired, removeThrowaway, startThrowaway, throwawayImage, throwawayName } from "./throwaway.mjs";

export const restoreLimit = 512 * 1024 ** 2;

const mongorestoreTimeoutMs = 20 * 60_000;
const checkout = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const teamHeavy = join(checkout, "bin", "team-heavy");
const script = join(checkout, "toolkits", "prod-mongo", "scripts", "restore-drill.mjs");
const signals = { SIGINT: 2, SIGTERM: 15, SIGHUP: 1 };

const plural = (n, word) => `${count(n)} ${word}${n === 1 ? "" : "s"}`;
// mongodump dumps every collection but those under system., except system.js.
const dumped = (name) => !name.startsWith("system.") || name === "system.js";

function shownFrom(home) {
  return (path) => (path === home ? "~" : path.startsWith(`${home}/`) ? `~/${path.slice(home.length + 1)}` : path);
}

export async function restoreDrill({ argv, database, root: configuredRoot }) {
  process.umask(0o077);
  const asText = argv.includes("--text");
  const rest = argv.filter((arg) => arg !== "--text");
  const home = homedir();
  const shown = shownFrom(home);
  const root = process.env.PROD_MONGO_ROOT ?? configuredRoot.replace(/^~(?=\/)/, home);
  const state = { name: undefined, removed: [], stamp: undefined, folder: undefined };

  const print = (result) => {
    writeSync(1, asText ? `${drillAnswer(result).text}\n` : `${JSON.stringify(result)}\n`);
  };
  const failed = (reason, cleanup) => ({
    failed: reason,
    stamp: state.stamp,
    folder: state.folder,
    container: state.name ?? null,
    removed: state.removed,
    cleanup: cleanup ?? null,
  });
  for (const [signal, number] of Object.entries(signals)) {
    process.on(signal, () => {
      const cleanup = state.name ? removeThrowaway(state.name) : null;
      print(failed(`the drill was stopped (${signal})`, cleanup));
      process.exit(128 + number);
    });
  }

  let result;
  try {
    result = await drill({ rest, database, root, shown, state });
  } catch (error) {
    if (error instanceof Refusal) result = { refused: error.message };
    else {
      const cleanup = state.name ? removeThrowaway(state.name) : null;
      result = failed(String(error?.message ?? error), cleanup);
    }
  }
  print(result);
  process.exit(result.verdict === "PASS" ? 0 : 1);
}

async function drill({ rest, database, root, shown, state }) {
  if (rest.length !== 1 || rest[0].startsWith("-")) {
    throw new Refusal("takes exactly one argument, a backup's name, its UTC start as 2026-11-08T142305Z (and --text for the answer as text)");
  }
  const shownRoot = shown(root);
  const { real, missing } = checkRoot(root, { shown });
  if (missing) throw new Refusal(`${shownRoot} does not exist yet, so it holds no backup to drill`);
  const { stamp, folder, manifest } = dumpByStamp(real, rest[0], shownRoot);
  const shownFolder = `${shownRoot}/${stamp}`;
  Object.assign(state, { stamp, folder: shownFolder });
  if (manifest.database !== database) throw new Refusal(`${shownFolder} is a dump of ${JSON.stringify(String(manifest.database)).slice(0, 40)}, not of ${database}`);
  const bytes = Number(manifest.totals?.bytes);
  if (!Number.isFinite(bytes) || bytes < 0) throw new Refusal(`${shownFolder}'s manifest gives no size`);
  if (bytes > restoreLimit) {
    throw new Refusal(`${shownFolder} is ${humanBytes(bytes)}, more than the ${humanBytes(restoreLimit)} a drill restores in memory`);
  }
  const versionRun = spawnSync("mongorestore", ["--version"], { env: childEnv(), stdio: ["ignore", "pipe", "pipe"], encoding: "utf8", timeout: 30_000 });
  if (versionRun.error?.code === "ENOENT") throw new Refusal("mongorestore is not installed: team-doctor names the install");
  const mongorestore = /^mongorestore version: (\S+)$/m.exec(versionRun.stdout ?? "")?.[1];
  if (!mongorestore) throw new Refusal("mongorestore --version gave no version: team-doctor names the install");
  let MongoClient;
  try {
    ({ MongoClient } = await import("mongodb"));
  } catch {
    throw new Refusal("the pinned MongoDB driver is not installed: run servers/install");
  }

  // Docker from here on.
  const started = Date.now();
  const at = stampOf(new Date(started));
  const drills = join(folder, "drills");
  const recordPath = join(drills, `${at}.json`);
  if (existsSync(recordPath)) throw new Refusal(`${shownFolder}/drills/${at}.json already exists: ask again in a second`);
  state.removed = removeExpired(started);
  state.name = throwawayName("drill");
  const throwaway = await startThrowaway({ name: state.name, kind: "drill", MongoClient });
  const scrubbed = scrubber(throwaway.uri);

  mkdirSync(drills, { recursive: true, mode: 0o700 });
  let restoreError;
  try {
    const restored = await runWithConfig(
      "mongorestore",
      (fifo) => [`--config=${fifo}`, "--nsInclude", `${database}.*`, "--gzip", "--dir", join(folder, "dump")],
      { fifo: join(drills, `.${at}.config.fifo`), config: yamlConfig("uri", throwaway.uri), timeoutMs: mongorestoreTimeoutMs },
    );
    if (restored.fedError) restoreError = `mongorestore never read its config: ${scrubbed(restored.fedError.message)}`;
    else if (restored.timedOut) restoreError = `mongorestore did not finish in ${duration(mongorestoreTimeoutMs)}, so it was killed`;
    else if (restored.code !== 0) {
      const why = scrubbed(lastLine(restored.stderr));
      restoreError = `mongorestore ${restored.signal ? `was killed (${restored.signal})` : `exited ${restored.code}`}${why ? `: ${why}` : ""}`;
    }
  } catch (error) {
    if (!error.mkfifo) throw new Error(`mongorestore could not start: ${scrubbed(error.message)}`);
    throw new Error(`mkfifo failed: ${scrubbed(error.message)}`);
  }

  const collections = await compare(throwaway.client, database, manifest);
  const verdict = !restoreError && collections.every(({ match }) => match) ? "PASS" : "FAIL";
  const cleanup = await throwaway.stop();
  state.name = undefined;
  const ended = Date.now();
  const record = {
    verdict,
    at,
    stamp,
    started: new Date(started).toISOString(),
    ended: new Date(ended).toISOString(),
    mongorestore,
    image: throwawayImage,
    ...(restoreError ? { restoreError } : {}),
    collections,
  };
  writeFileSync(recordPath, `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  return {
    verdict,
    stamp,
    folder: shownFolder,
    at,
    record: `${shownFolder}/drills/${at}.json`,
    seconds: Math.round((ended - started) / 1000),
    mongorestore,
    container: throwaway.name,
    collections,
    ...(restoreError ? { restoreError } : {}),
    removed: state.removed,
    cleanup,
  };
}

// Each manifest entry against what the throwaway holds, then anything it holds the manifest does
// not name.
async function compare(client, database, manifest) {
  const db = client.db(database);
  const listed = (await db.listCollections({}, { nameOnly: false }).toArray()).filter(({ name }) => dumped(name));
  const restored = new Map();
  for (const { name, type } of listed) {
    if (type === "view") restored.set(name, { type: "view" });
    else {
      const indexes = (await db.collection(name).indexes()).map((index) => index.name).sort();
      restored.set(name, { type: "collection", documents: await db.collection(name).countDocuments({}), indexes });
    }
  }
  const entries = (Array.isArray(manifest.collections) ? manifest.collections : []).map(({ name, type, dumped: documents, indexes }) => {
    const expected = type === "view" ? { type: "view" } : { type: "collection", documents, indexes: [...(indexes ?? [])].sort() };
    const found = restored.get(name) ?? null;
    restored.delete(name);
    const match =
      found !== null &&
      found.type === expected.type &&
      (expected.type === "view" || (found.documents === expected.documents && found.indexes.join("\n") === expected.indexes.join("\n")));
    return { name, expected, restored: found, match };
  });
  for (const [name, found] of restored) entries.push({ name, expected: null, restored: found, match: false });
  return entries;
}

export async function drillTool({ input, root, shown, scrubbed, progress }) {
  const shownRoot = shown(root);
  const { real, missing, note } = checkRoot(root, { shown });
  if (missing) throw new Refusal(`${shownRoot} does not exist yet, so it holds no backup to drill`);
  const stamp = input.backup ?? listRoot(real).dumps.find(({ verified }) => verified)?.stamp;
  if (stamp === undefined) throw new Refusal(`${shownRoot} holds no verified backup to drill: take one with backup first`);
  dumpByStamp(real, stamp, shownRoot);

  // PROD_MONGO_HEAVY_WAIT_MINUTES replaces the 20 minutes, for the tests only.
  const wait = /^\d+$/.test(process.env.PROD_MONGO_HEAVY_WAIT_MINUTES ?? "") ? process.env.PROD_MONGO_HEAVY_WAIT_MINUTES : "20";
  // What team-heavy needs beyond childEnv: the team home and systemd's user manager, for its
  // admission and its scope; PROD_MONGO_ROOT when the server has one.
  const extra = {};
  for (const key of ["PROD_MONGO_ROOT", "TEAM_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]) {
    if (process.env[key] !== undefined) extra[key] = process.env[key];
  }
  progress(`drilling ${stamp}, through the machine's heavy-run lock`);
  const args = ["run", "--wait", wait, "--kind", "restore-drill", "--label", `prod-mongo restore-drill ${stamp}`, "--", process.execPath, script, stamp];
  let ran;
  try {
    // TERM, so the script removes its throwaway before it ends.
    ran = await run(teamHeavy, args, { env: childEnv(extra), timeoutMs: (Number(wait) + 30) * 60_000, killSignal: "SIGTERM" });
  } catch (error) {
    throw new Refusal(`team-heavy could not start: ${scrubbed(error.message)}`);
  }
  if (ran.code === 75) {
    const why = scrubbed(lastLine(ran.stderr)).replace(/^team-heavy: /, "");
    return { text: `restore-drill: the machine is busy: ${why}; ask again later`, isError: true };
  }
  let result;
  try {
    result = JSON.parse(ran.stdout.trim().split("\n").at(-1));
  } catch {
    const why = scrubbed(lastLine(ran.stderr));
    throw new Refusal(`the drill gave no result (${ran.timedOut ? "stopped after its time ran out" : `exit ${ran.code ?? ran.signal}`})${why ? `: ${why}` : ""}`);
  }
  const answer = drillAnswer(result);
  return note ? { ...answer, text: `${answer.text}\n${note}` } : answer;
}

function kindsOf(entries) {
  const collections = entries.filter(({ type }) => type === "collection").length;
  const views = entries.filter(({ type }) => type === "view").length;
  return [plural(collections, "collection"), ...(views ? [plural(views, "view")] : [])].join(" and ");
}

function mismatch({ name, expected, restored }) {
  if (expected === null) return `- ${name}: restored, but its manifest does not name it`;
  if (restored === null) return `- ${name}: ${expected.type === "view" ? "the view was" : "it was"} not restored`;
  if (restored.type !== expected.type) return `- ${name}: restored as a ${restored.type}, its manifest says a ${expected.type}`;
  const parts = [];
  if (restored.documents !== expected.documents) parts.push(`${plural(restored.documents, "document")} restored, ${count(expected.documents ?? 0)} in its manifest`);
  if (restored.indexes.join("\n") !== expected.indexes.join("\n")) parts.push(`indexes ${restored.indexes.join(", ") || "none"} restored, ${expected.indexes.join(", ") || "none"} in its manifest`);
  return `- ${name}: ${parts.join("; ")}`;
}

function cleanupClause({ container, cleanup }) {
  if (!container || cleanup?.gone) return "nothing was left running";
  return `the throwaway MongoDB ${container} could not be removed (${cleanup?.error ?? "unknown"}), but it ends itself within the hour`;
}

function removedLines(removed = []) {
  const lines = [];
  const gone = removed.filter(({ error }) => !error);
  if (gone.length) lines.push(`Removed what an earlier run left past its expiry: ${gone.map(({ type, name }) => `${type} ${name}`).join(", ")}.`);
  for (const { type, name, error } of removed.filter(({ error }) => error)) lines.push(`Could not remove the expired ${type} ${name}: ${error}.`);
  return lines;
}

export function drillAnswer(result) {
  if (result.refused) return { text: `restore-drill: failed: ${result.refused}`, isError: true };
  if (result.failed) {
    return { text: [`restore-drill: failed: ${result.failed}, so ${result.folder ?? "the dump"} has no verdict; ${cleanupClause(result)}.`, ...removedLines(result.removed)].join("\n"), isError: true };
  }
  const { verdict, folder, seconds, mongorestore, collections, restoreError, record } = result;
  const expected = collections.filter(({ expected: e }) => e !== null).map(({ expected: e }) => e);
  const lines = [`Restore drill of ${folder}: ${verdict} in ${duration(seconds * 1000)}, mongorestore ${mongorestore}`];
  if (restoreError) lines.push(`${restoreError}, so the dump did not restore.`);
  const bad = collections.filter(({ match }) => !match);
  if (!bad.length) {
    const documents = expected.reduce((sum, { documents }) => sum + (documents ?? 0), 0);
    lines.push(`${kindsOf(expected)}, ${plural(documents, "document")}, each collection's count and index names as its manifest gives them.`);
  } else {
    lines.push(`${count(bad.length)} of ${count(collections.length)} did not match the manifest:`);
    lines.push(...bad.map(mismatch));
  }
  lines.push(`Recorded in ${record}; ${cleanupClause(result)}.`);
  lines.push(...removedLines(result.removed));
  return { text: lines.join("\n"), isError: verdict !== "PASS" };
}
