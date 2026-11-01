// A throwaway local MongoDB for the toolkit tests: one container per test file, at the exact
// version production runs, on a random loopback port, with its data on tmpfs, removed when the
// file is done.
//
//   const db = await startMongo();           before()
//   db.uri(user, password, options)          a connection string for a test user
//   await db.createUser(user, password, roles)
//   await db.connectAs(user, password)       a driver client as a test user; close it when done
//   await db.seed(database, { collection: [documents] })   beforeEach(): drop, then insert
//   db.client                                a driver client as root, for checking the data
//   await db.stop();                         after()
// startMongo waits for the server with connectWhenReady, and stop() removes the container with
// removeContainer; both are exported for their own tests.
import { execFileSync, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import { join } from "node:path";
import { repoRoot } from "./mcp.mjs";

// Production is Atlas on MongoDB 8.0.
export const mongoImage = "mongo:8.0.34@sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907";

// MongoDB 8.0 exits at start on Linux 6.19 to 7.0.13 when tcmalloc runs on per-CPU caches, whose
// rseq use those kernels break (SERVER-121912, SERVER-125742). The image turns glibc's rseq off
// (GLIBC_TUNABLES=glibc.pthread.rseq=0) so tcmalloc can take rseq for those caches; turning it back
// on leaves tcmalloc on per-thread caches, which mongod's startup check lets start
// (docs/v8.0/administration/tcmalloc-performance). Drop this once GitHub's runners are on 7.0.14
// or later, where 8.0.30 and newer start with per-CPU caches.
const perThreadCaches = ["--env", "GLIBC_TUNABLES=glibc.pthread.rseq=1"];

// The image declares /data/db and /data/configdb as volumes, so a container with nothing mounted
// there gets two anonymous volumes, about 0.3 GB a pair, which a run killed before its after() and
// a later docker rm without --volumes leave on disk. On tmpfs Docker makes none, so whatever ends
// the run leaves at most a container. Every container of the image takes these.
export const dataOnTmpfs = ["--tmpfs", "/data/db", "--tmpfs", "/data/configdb"];

// The driver from the pinned server's own install (servers/install), so the tests add no
// dependency of their own.
const { MongoClient } = createRequire(join(repoRoot, "servers", "package.json"))("mongodb");

const docker = (...args) => execFileSync("docker", args, { encoding: "utf8" }).trim();

// Removes container <name>, and with --volumes any anonymous volume it has, which dataOnTmpfs
// leaves none of unless the image declares a new one.
export function removeContainer(name) {
  docker("rm", "--force", "--volumes", name);
}

export async function startMongo() {
  const rootPassword = randomBytes(12).toString("hex");
  const name = `toolkit-test-${randomBytes(4).toString("hex")}`;
  docker(
    "run", "--detach", "--name", name, "--label", "agent-team-test=toolkits",
    "--publish", "127.0.0.1::27017",
    "--env", "MONGO_INITDB_ROOT_USERNAME=root", "--env", `MONGO_INITDB_ROOT_PASSWORD=${rootPassword}`,
    ...perThreadCaches, ...dataOnTmpfs,
    mongoImage,
  );
  try {
    const port = Number(docker("port", name, "27017/tcp").split("\n")[0].split(":").at(-1));
    const uri = (user, password, options = "") =>
      `mongodb://${user}:${password}@127.0.0.1:${port}/?authSource=admin${options}`;
    const client = await connectWhenReady(uri("root", rootPassword), name);
    return {
      name,
      port,
      uri,
      client,
      createUser: (user, password, roles) =>
        client.db("admin").command({ createUser: user, pwd: password, roles }),
      connectAs: (user, password) => new MongoClient(uri(user, password)).connect(),
      async seed(database, collections) {
        await client.db(database).dropDatabase();
        for (const [collection, documents] of Object.entries(collections)) {
          await client.db(database).collection(collection).insertMany(documents);
        }
      },
      async stop() {
        await client.close();
        removeContainer(name);
      },
    };
  } catch (error) {
    removeContainer(name);
    throw error;
  }
}

// The image's entrypoint restarts mongod once after creating the root user, so wait for a ping
// that holds: up to <waitMs> (180 s, since a Docker busy starting other stacks can take minutes),
// then fail with the time waited and container <name>'s last log lines. A container that exits
// first fails the wait at once with its exit code: startMongo runs it without --rm, so it is still
// there to read.
export async function connectWhenReady(uri, name, waitMs = 180_000) {
  const start = Date.now();
  for (;;) {
    const client = new MongoClient(uri, { serverSelectionTimeoutMS: 1_000 });
    try {
      await client.connect();
      await client.db("admin").command({ ping: 1 });
      return client;
    } catch (error) {
      await client.close().catch(() => {});
      const exited = exitOf(name);
      if (exited) {
        const waited = Math.round((Date.now() - start) / 1_000);
        throw new Error(
          `MongoDB container ${name} ${exited} after ${waited} s, before it was ready\n` +
            `docker logs --tail 20 ${name}:\n${lastLogLines(name)}`,
          { cause: error },
        );
      }
      if (Date.now() - start > waitMs) {
        const waited = Math.round((Date.now() - start) / 1_000);
        throw new Error(
          `MongoDB in container ${name} was not ready after ${waited} s: ${error.message}\n` +
            `docker logs --tail 20 ${name}:\n${lastLogLines(name)}`,
          { cause: error },
        );
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
}

// How container <name> ended ("exited with code 137, killed out of memory"), or null while it runs
// or while Docker is too busy to say.
function exitOf(name) {
  const state = spawnSync("docker", ["inspect", "--format", "{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}", name], { encoding: "utf8" });
  if (state.error || state.status !== 0) {
    return /no such object/i.test(state.stderr ?? "") ? `was gone (${state.stderr.trim()})` : null;
  }
  const [status, code, oom] = state.stdout.trim().split(" ");
  if (["created", "running", "restarting", "paused"].includes(status)) return null;
  return `exited with code ${code}${oom === "true" ? ", killed out of memory" : ""}`;
}

// Container <name>'s last 20 log lines, stdout and stderr, or why docker could not read them.
function lastLogLines(name) {
  const logs = spawnSync("docker", ["logs", "--tail", "20", name], { encoding: "utf8" });
  if (logs.error || logs.status !== 0) {
    return `(docker logs failed: ${(logs.error?.message ?? logs.stderr).trim()})`;
  }
  return `${logs.stdout}${logs.stderr}`.trim() || "(nothing logged)";
}
