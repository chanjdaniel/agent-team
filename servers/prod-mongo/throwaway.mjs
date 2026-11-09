// The throwaway MongoDB: the only code that starts a container with production data in it, which
// the restore drill (restore-drill.mjs) and the migration rehearsal restore a dump into.
//
//   throwawayImage           the pinned image, production's major version; the toolkit test holds
//                            it equal to tests/toolkits/helpers/mongo.mjs's
//   perThreadCaches          the image's environment that lets MongoDB 8.0 start on the kernels
//                            whose rseq change breaks tcmalloc's per-CPU caches, as the helper's
//   teamLabel(key)           a team label's full key, io.github.chanjdaniel.team.<key>
//   toolkitLabels({ kind, expires })   the --label arguments of every container, network and
//                            image the toolkit makes: owner=agent-team, kind, toolkit=prod-mongo,
//                            task (AGENT_TEAM_TASK, when set) and expires
//   removeExpired(now)       removes, by id, every container, network and image labelled
//                            toolkit=prod-mongo whose expires has passed (what a killed run left),
//                            in that order; returns [{ type, name, expires, error? }]
//   throwawayName(kind)      a new container name, prod-mongo-<kind>-<12 hex>, which the caller
//                            holds before the start, so a signal during it can still remove it
//   await startThrowaway({ name, kind, join, MongoClient })
//                            starts one and waits until its root user can ping it; resolves
//                            { name, port, expires, uri, password, client, stop() }; on any failure
//                            it removes the container first, then rejects
//   removeThrowaway(name)    kills a docker run still starting one, removes the container (docker rm
//                            --force), then checks it is gone: { gone: true } or { gone: false,
//                            error }; synchronous, for a signal
//   throwaway.stop()         closes the client, then removeThrowaway
//
// The container: the pinned image with its data and config on tmpfs, so restored personal data
// never touches a Docker volume or the disk; a 2 GiB memory cap with no swap; --rm; published on a
// random loopback port only (127.0.0.1::27017); a root user whose random password reaches the
// container as a name-only `-e MONGO_INITDB_ROOT_PASSWORD`, its value in the docker CLI child's own
// environment, never an argument list; and the image's own entrypoint under `timeout 3600`, so
// even a run killed with SIGKILL leaves no MongoDB running past the hour, and --rm removes it then.
// `join`, { network, alias }, connects it to a network of the caller's under that alias too (the
// rehearsal's internal network, as `mongodb`).
// Every docker call gets childEnv() alone (children.mjs), the password added only to `docker run`'s.
// Every call but `docker run` is synchronous and short; `docker run`, which may pull the image, runs
// without blocking, so a signal is handled while it waits.
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { childEnv, lastLine, run } from "./children.mjs";

// Production is Atlas on MongoDB 8.0.
export const throwawayImage = "mongo:8.0.34@sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907";

// tcmalloc on per-thread caches, which mongod's startup check lets start on every kernel (see
// tests/toolkits/helpers/mongo.mjs, SERVER-121912).
export const perThreadCaches = ["--env", "GLIBC_TUNABLES=glibc.pthread.rseq=1"];

const lifeSeconds = 3600;
const readyMs = 180_000;
const toolkit = "prod-mongo";

export const teamLabel = (key) => `io.github.chanjdaniel.team.${key}`;

const isoSecond = (ms) => `${new Date(ms).toISOString().slice(0, 19)}Z`;

export function toolkitLabels({ kind, expires }) {
  const task = /^T\d+$/.test(process.env.AGENT_TEAM_TASK ?? "") ? process.env.AGENT_TEAM_TASK : undefined;
  const labels = { owner: "agent-team", kind, toolkit, ...(task ? { task } : {}), expires };
  return Object.entries(labels).flatMap(([key, value]) => ["--label", `${teamLabel(key)}=${value}`]);
}

function docker(args, { env = childEnv(), timeoutMs = 60_000 } = {}) {
  const result = spawnSync("docker", args, { env, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8", timeout: timeoutMs });
  if (result.error) {
    const why = result.error.code === "ENOENT" ? "docker is not installed" : result.error.message;
    return { ok: false, stdout: "", why };
  }
  return { ok: result.status === 0, stdout: result.stdout.trim(), why: lastLine(result.stderr) || `docker ${args[0]} exited ${result.status}` };
}

const kinds = [
  { type: "container", list: ["container", "ls", "--all", "--quiet", "--no-trunc"], inspect: "container", labels: (o) => o.Config?.Labels, name: (o) => o.Name?.replace(/^\//, ""), remove: ["rm", "--force", "--volumes"] },
  { type: "network", list: ["network", "ls", "--quiet", "--no-trunc"], inspect: "network", labels: (o) => o.Labels, name: (o) => o.Name, remove: ["network", "rm"] },
  { type: "image", list: ["image", "ls", "--quiet", "--no-trunc"], inspect: "image", labels: (o) => o.Config?.Labels, name: (o) => o.RepoTags?.[0], remove: ["image", "rm", "--force"] },
];

export function removeExpired(now = Date.now()) {
  const removed = [];
  for (const kind of kinds) {
    const listed = docker([...kind.list, "--filter", `label=${teamLabel("toolkit")}=${toolkit}`]);
    if (!listed.ok) throw new Error(`docker could not list the toolkit's ${kind.type}s: ${listed.why}`);
    for (const id of [...new Set(listed.stdout.split("\n").filter(Boolean))]) {
      // One at a time: a container --rm removes between the list and here is simply gone.
      const inspected = docker([kind.inspect, "inspect", id]);
      if (!inspected.ok) continue;
      const [object] = JSON.parse(inspected.stdout);
      const labels = kind.labels(object) ?? {};
      if (labels[teamLabel("toolkit")] !== toolkit) continue;
      const expires = labels[teamLabel("expires")];
      const at = Date.parse(expires ?? "");
      if (!Number.isFinite(at) || at >= now) continue;
      const name = kind.name(object) || id.replace(/^sha256:/, "").slice(0, 12);
      const gone = docker([...kind.remove, id]);
      removed.push({ type: kind.type, name, expires, ...(gone.ok ? {} : { error: gone.why }) });
    }
  }
  return removed;
}

export const throwawayName = (kind) => `${toolkit}-${kind}-${randomBytes(6).toString("hex")}`;

// The docker run children still running, which removeThrowaway kills first, so a run a signal
// interrupts never goes on to start a container after its maker is gone.
const starting = new Set();

export function removeThrowaway(name) {
  for (const child of starting) child.kill("SIGKILL");
  const gone = docker(["rm", "--force", "--volumes", name]);
  const left = docker(["container", "inspect", "--format", "{{.Id}}", name]);
  if (!left.ok && /no such (container|object)/i.test(left.why)) return { gone: true };
  return { gone: false, error: gone.ok ? "it is still there" : gone.why };
}

export async function startThrowaway({ name, kind, join, MongoClient }) {
  const password = randomBytes(24).toString("hex");
  const expires = isoSecond(Date.now() + lifeSeconds * 1000);
  const remove = () => removeThrowaway(name);
  const started = await dockerRun(
    [
      "run", "--detach", "--rm", "--name", name,
      ...toolkitLabels({ kind, expires }),
      "--memory", "2g", "--memory-swap", "2g",
      "--publish", "127.0.0.1::27017",
      "--tmpfs", "/data/db", "--tmpfs", "/data/configdb",
      ...perThreadCaches,
      "--env", "MONGO_INITDB_ROOT_USERNAME=root", "--env", "MONGO_INITDB_ROOT_PASSWORD",
      "--entrypoint", "timeout",
      throwawayImage, String(lifeSeconds), "docker-entrypoint.sh", "mongod",
    ],
    childEnv({ MONGO_INITDB_ROOT_PASSWORD: password }),
  );
  if (!started.ok) {
    remove();
    throw new Error(`docker could not start the throwaway MongoDB: ${started.why}`);
  }
  let client;
  try {
    if (join) {
      const joined = docker(["network", "connect", "--alias", join.alias, join.network, name]);
      if (!joined.ok) throw new Error(`docker could not connect the throwaway MongoDB to ${join.network}: ${joined.why}`);
    }
    const published = docker(["port", name, "27017/tcp"]);
    const port = Number(/127\.0\.0\.1:(\d+)/.exec(published.stdout)?.[1]);
    if (!published.ok || !port) throw new Error(`docker gave no loopback port for the throwaway MongoDB: ${published.why}`);
    const uri = `mongodb://root:${password}@127.0.0.1:${port}/?authSource=admin`;
    client = await whenReady(uri, name, MongoClient);
    return {
      name,
      port,
      expires,
      uri,
      password,
      client,
      async stop() {
        await client.close().catch(() => {});
        return remove();
      },
    };
  } catch (error) {
    await client?.close().catch(() => {});
    remove();
    throw error;
  }
}

// docker run, as docker() answers, but without blocking: pulling the image the first time can take
// minutes, and a signal meanwhile must be handled at once.
async function dockerRun(args, env) {
  let result;
  try {
    result = await run("docker", args, {
      env,
      timeoutMs: 10 * 60_000,
      onSpawn: (child) => {
        starting.add(child);
        child.on("exit", () => starting.delete(child));
      },
    });
  } catch (error) {
    return { ok: false, stdout: "", why: error.code === "ENOENT" ? "docker is not installed" : error.message };
  }
  if (result.timedOut) return { ok: false, stdout: "", why: "docker run did not finish in 10 min" };
  return { ok: result.code === 0, stdout: result.stdout.trim(), why: lastLine(result.stderr) || `docker run exited ${result.code ?? result.signal}` };
}

// The image's entrypoint restarts mongod once after creating the root user, so wait for a ping
// that holds, up to 3 minutes; a container that ends first (--rm removes it) fails the wait at once.
async function whenReady(uri, name, MongoClient) {
  const start = Date.now();
  for (;;) {
    const client = new MongoClient(uri, { serverSelectionTimeoutMS: 1_000 });
    try {
      await client.connect();
      await client.db("admin").command({ ping: 1 });
      return client;
    } catch {
      await client.close().catch(() => {});
      const state = docker(["container", "inspect", "--format", "{{.State.Status}}", name]);
      if (!state.ok && /no such (container|object)/i.test(state.why)) throw new Error("the throwaway MongoDB ended before it was ready");
      if (state.ok && !["created", "running", "restarting"].includes(state.stdout)) throw new Error(`the throwaway MongoDB is ${state.stdout}, not ready`);
      if (Date.now() - start > readyMs) throw new Error(`the throwaway MongoDB was not ready after ${Math.round((Date.now() - start) / 1000)} s`);
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
}
