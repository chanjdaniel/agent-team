// A fake of Vercel's REST API on the loopback, for the vercel-read server, which reaches it only
// through VERCEL_READ_API. It answers as Vercel's docs say a project-scoped token is answered,
// from fixtures the test sets, and logs every request it gets.
//
//   const vercel = await startFakeVercel({ projects: { "front-end": { id, token }, ... } });
//   vercel.origin, vercel.port      http://127.0.0.1:<random port>, for VERCEL_READ_API
//   vercel.deployments[projectId]   the project's deployments, as Vercel gives them; a test sets them.
//                                   A deployment's own `projectId`, when it has one, is the one
//                                   GET /v13/deployments answers, so a test can make Vercel name
//                                   another project than the one holding it
//   vercel.aliases[host] = uid      the deployment a domain serves, as Vercel's alias points it
//   vercel.domains[projectId]       the project's domains, as GET /v9/projects/<id>/domains gives them
//   vercel.envs[projectId]          the project's environment variables, as GET /v10/projects/<id>/env
//                                   gives them without decrypt, values included
//   vercel.scope[label] = "all"     that project's token reaches every project, as a team-scoped
//                                   or full-account token does; "none", no project; "project",
//                                   the default, its own only
//   vercel.logs[deploymentId] = { projectId, lines, interval, end, answer }
//                                   that deployment's runtime logs: each of `lines` an object, sent
//                                   as one JSON line, or a string, sent exactly as it is (so a test
//                                   can split a line or send one that is not JSON), `interval`
//                                   milliseconds apart (5 by default); with `end: false` the stream
//                                   never ends after its last line, as a live one does not; with
//                                   `answer: false` the fake never sends the answer's headers
//   vercel.streams                  each runtime-logs stream the fake opened, in order:
//                                   { deploymentId, sent, ended, closed }, `sent` the writes so far,
//                                   `ended` whether the fake ended it, and `closed` a promise that
//                                   settles when its connection closed, by either side
//   vercel.requests()               every request so far: { method, path, query, token }, `token`
//                                   the label of the project whose token it carried, "unknown"
//                                   for any other token and null for none; query as an object
//   vercel.seen()                   every request since the fake started, as requests() gives them,
//                                   which reset() never forgets: what the whole file's runs sent
//   vercel.reset()                  forgets the requests, the streams, the logs, the aliases, the
//                                   domains and the environment variables
//   await vercel.close()
//
// A request with no token, or one the fake does not know, is answered 403 with Vercel's
// invalidToken error; a project-scoped token naming another project's id is answered 403
// forbidden. GET /v7/deployments filters by projectId, target, state and until, newest first, to
// at most `limit` (Vercel's 20 by default), with pagination.next the oldest one's `created` when
// older ones remain; it never answers a deployment's gitSource. GET /v13/deployments/<id, url or
// alias> answers the deployment, with `id` for its `uid`, its `projectId`, no
// `isRollbackCandidate` (Vercel's lookup has none, only its list), and its `gitSource` only with
// withGitRepoInfo=true, 403 when the token does not reach the project holding it, or
// 404 when there is none. GET /v9/projects/<projectId>/domains answers the project's domains.
// GET /v1/projects/<projectId>/deployments/<deploymentId>/runtime-logs streams the deployment's
// logs as application/stream+json, and is answered 404 for a deployment it has no logs of or
// whose logs are another project's. Any other method or path is answered 404.
import { createServer } from "node:http";

const error = (code, message, extra = {}) => ({ error: { code, message, ...extra } });
const deploymentPath = /^\/v13\/deployments\/([^/]+)$/;
const domainsPath = /^\/v9\/projects\/([^/]+)\/domains$/;
const envPath = /^\/v10\/projects\/([^/]+)\/env$/;
const logsPath = /^\/v1\/projects\/([^/]+)\/deployments\/([^/]+)\/runtime-logs$/;

export async function startFakeVercel({ projects }) {
  const log = [];
  const everyRequest = [];
  const labelOf = new Map(Object.entries(projects).map(([label, { token }]) => [token, label]));
  const fake = {
    deployments: Object.fromEntries(Object.values(projects).map(({ id }) => [id, []])),
    scope: Object.fromEntries(Object.keys(projects).map((label) => [label, "project"])),
    logs: {},
    aliases: {},
    domains: {},
    envs: {},
    streams: [],
    requests: () => log.map((entry) => ({ ...entry, query: { ...entry.query } })),
    seen: () => everyRequest.map((entry) => ({ ...entry, query: { ...entry.query } })),
    reset: () => {
      log.splice(0);
      fake.streams.splice(0);
      fake.logs = {};
      fake.aliases = {};
      fake.domains = {};
      fake.envs = {};
    },
  };

  // Whether the token's project may read projectId.
  const reaches = (label, projectId) =>
    fake.scope[label] === "all" || (fake.scope[label] === "project" && projects[label].id === projectId);

  const answer = (url, label) => {
    const query = Object.fromEntries(url.searchParams);
    if (url.pathname === "/v7/deployments") {
      if (!query.projectId) return [400, error("bad_request", "projectId is required by this fake")];
      if (!reaches(label, query.projectId)) return [403, error("forbidden", "Not authorized")];
      const limit = query.limit === undefined ? 20 : Number(query.limit);
      const matching = (fake.deployments[query.projectId] ?? [])
        .filter((deployment) => query.target === undefined || deployment.target === query.target)
        .filter((deployment) => query.state === undefined || deployment.state === query.state)
        .filter((deployment) => query.until === undefined || deployment.created < Number(query.until))
        .sort((a, b) => b.created - a.created);
      const deployments = matching.slice(0, limit).map(({ gitSource, ...listed }) => listed);
      const more = matching.length > deployments.length;
      return [200, {
        deployments,
        pagination: { count: deployments.length, next: more ? deployments.at(-1).created : null, prev: null },
      }];
    }
    const single = url.pathname.match(deploymentPath);
    if (single) {
      const idOrHost = decodeURIComponent(single[1]);
      const uid = fake.aliases[idOrHost] ?? idOrHost;
      for (const [holder, list] of Object.entries(fake.deployments)) {
        const found = list.find((deployment) => deployment.uid === uid || deployment.url === idOrHost);
        if (!found) continue;
        if (!reaches(label, holder)) return [403, error("forbidden", "Not authorized")];
        const { uid: id, gitSource, isRollbackCandidate, ...rest } = found;
        return [200, {
          id,
          ...rest,
          projectId: found.projectId ?? holder,
          ...(query.withGitRepoInfo === "true" && gitSource ? { gitSource } : {}),
        }];
      }
      return [404, error("not_found", "The deployment was not found")];
    }
    const domains = url.pathname.match(domainsPath);
    if (domains) {
      const [, projectId] = domains;
      if (!reaches(label, projectId)) return [403, error("forbidden", "Not authorized")];
      const list = fake.domains[projectId] ?? [];
      return [200, { domains: list, pagination: { count: list.length, next: null, prev: null } }];
    }
    const env = url.pathname.match(envPath);
    if (env) {
      const [, projectId] = env;
      if (!reaches(label, projectId)) return [403, error("forbidden", "Not authorized")];
      const envs = fake.envs[projectId] ?? [];
      return [200, { envs, pagination: { count: envs.length, next: null, prev: null } }];
    }
    const logs = url.pathname.match(logsPath);
    if (logs) {
      const [, projectId, deploymentId] = logs;
      if (!reaches(label, projectId)) return [403, error("forbidden", "Not authorized")];
      const fixture = fake.logs[deploymentId];
      if (!fixture || fixture.projectId !== projectId) return [404, error("not_found", "The deployment was not found")];
      return [200, fixture, deploymentId];
    }
    return [404, error("not_found", "The requested path was not found")];
  };

  // Write a deployment's log lines over time, then end the stream unless the fixture says not.
  const streamLogs = (res, deploymentId, { lines, interval = 5, end = true, answer: answers = true }) => {
    const stream = { deploymentId, sent: 0, ended: false };
    stream.closed = new Promise((resolve) => res.on("close", resolve));
    fake.streams.push(stream);
    if (!answers) return;
    res.writeHead(200, { "content-type": "application/stream+json" });
    let timer;
    res.on("close", () => clearTimeout(timer));
    const next = () => {
      if (res.destroyed) return;
      if (stream.sent < lines.length) {
        const line = lines[stream.sent];
        res.write(typeof line === "string" ? line : `${JSON.stringify(line)}\n`);
        stream.sent += 1;
        timer = setTimeout(next, interval);
      } else if (end) {
        stream.ended = true;
        res.end();
      }
    };
    next();
  };

  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://127.0.0.1");
    const bearer = req.headers.authorization?.match(/^Bearer (.*)$/)?.[1];
    const label = bearer === undefined ? null : (labelOf.get(bearer) ?? "unknown");
    const entry = { method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), token: label };
    log.push(entry);
    everyRequest.push(entry);
    const [status, body, deploymentId] = req.method !== "GET" ? [404, error("not_found", "The requested path was not found")]
      : label === null || label === "unknown" ? [403, error("forbidden", "Not authorized", { invalidToken: true })]
      : answer(url, label);
    if (deploymentId !== undefined) return streamLogs(res, deploymentId, body);
    res.writeHead(status, { "content-type": "application/json; charset=utf-8" });
    res.end(JSON.stringify(body));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  fake.origin = `http://127.0.0.1:${server.address().port}`;
  fake.port = server.address().port;
  fake.close = () => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  });
  return fake;
}
