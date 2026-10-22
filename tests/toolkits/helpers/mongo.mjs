// A throwaway local MongoDB for the toolkit tests: one container per test file, at the exact
// version production runs, on a random loopback port, removed when the file is done.
//
//   const db = await startMongo();           before()
//   db.uri(user, password, options)          a connection string for a test user
//   await db.createUser(user, password, roles)
//   await db.connectAs(user, password)       a driver client as a test user; close it when done
//   await db.seed(database, { collection: [documents] })   beforeEach(): drop, then insert
//   db.client                                a driver client as root, for checking the data
//   await db.stop();                         after()
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import { join } from "node:path";
import { repoRoot } from "./mcp.mjs";

// Production is Atlas on MongoDB 8.0.
export const mongoImage = "mongo:8.0.34@sha256:4a4ab5d4834207389e0d7270fac988e21ffedccecba77991a552f755df229907";

// The driver from the pinned server's own install (servers/install), so the tests add no
// dependency of their own.
const { MongoClient } = createRequire(join(repoRoot, "servers", "package.json"))("mongodb");

const docker = (...args) => execFileSync("docker", args, { encoding: "utf8" }).trim();

export async function startMongo() {
  const rootPassword = randomBytes(12).toString("hex");
  const name = `toolkit-test-${randomBytes(4).toString("hex")}`;
  docker(
    "run", "--detach", "--rm", "--name", name, "--label", "agent-team-test=toolkits",
    "--publish", "127.0.0.1::27017",
    "--env", "MONGO_INITDB_ROOT_USERNAME=root", "--env", `MONGO_INITDB_ROOT_PASSWORD=${rootPassword}`,
    mongoImage,
  );
  try {
    const port = Number(docker("port", name, "27017/tcp").split("\n")[0].split(":").at(-1));
    const uri = (user, password, options = "") =>
      `mongodb://${user}:${password}@127.0.0.1:${port}/?authSource=admin${options}`;
    const client = await connectWhenReady(uri("root", rootPassword));
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
        docker("rm", "--force", name);
      },
    };
  } catch (error) {
    docker("rm", "--force", name);
    throw error;
  }
}

// The image's entrypoint restarts mongod once after creating the root user, so wait for a ping
// that holds.
async function connectWhenReady(uri) {
  const deadline = Date.now() + 60_000;
  for (;;) {
    const client = new MongoClient(uri, { serverSelectionTimeoutMS: 1_000 });
    try {
      await client.connect();
      await client.db("admin").command({ ping: 1 });
      return client;
    } catch (error) {
      await client.close().catch(() => {});
      if (Date.now() > deadline) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
}
