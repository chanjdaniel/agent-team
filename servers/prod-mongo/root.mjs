// prod-mongo's backups root: where it may be, and a dump in it taken by its stamp.
//
//   destinationRefusal(path, context)
//                            why `path` may not hold the backups, naming the rule, or nothing: a
//                            pure function of `path` and `context`, which rootContext builds
//   rootContext(path, { env, platform })
//                            the machine's context for `path`: its real path, the home, the team
//                            home (found as bin/lib/team.sh finds it), Node's temporary directory,
//                            the environment, the platform, what each real ancestor holds of
//                            `.git` and the sync clients' markers, and each named directory's real
//                            path
//   realPathOf(path)         `path` with every symlink resolved, through its nearest existing
//                            ancestor when it does not exist yet
//   checkRoot(root, { create, shown })
//                            { real, note, missing }: the root's real path once every rule passes
//                            and it is a directory of this user's, made (0700) when `create`, else
//                            `missing` when it is not there; its mode is set to 0700 when looser,
//                            and `note` says so; a Refusal otherwise
//   dumpByStamp(real, stamp, shownRoot)
//                            { stamp, folder, manifest }: the dump named `stamp` (stampPattern, never
//                            a path) directly under the root, a folder with a verified manifest.json;
//                            a Refusal for anything else
//   stampPattern, partialPattern   a dump's folder name, and a backup's unfinished one
//   backupsRoot(configured)  { root, home, shown }: the root `configured` names from ~/ (PROD_MONGO_ROOT
//                            replaces it, for the tests only), the home, and shown(path), a path
//                            written from ~/ when it is under the home, since the home's own path
//                            holds the account's name
//
// Every rule applies to the path as given and to its real path, so a symlink never takes the
// backups into a place a rule keeps them out of.
import { chmodSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, normalize, resolve, sep } from "node:path";
import { Refusal } from "./refusal.mjs";

export const stampPattern = /^\d{4}-\d{2}-\d{2}T\d{6}Z$/;
export const partialPattern = /^\.\d{4}-\d{2}-\d{2}T\d{6}Z\.partial$/;

// Under the home directory, the folders a sync client keeps in step with another machine.
const syncedUnderHome = ["Box", "Dropbox", "Google Drive", "GoogleDrive", "iCloud Drive", "Library/CloudStorage", "Library/Mobile Documents", "MEGA", "Nextcloud", "OneDrive", "ownCloud", "pCloudDrive", "Sync"];
// On macOS, iCloud's Desktop and Documents sync may hold these.
const syncedOnMac = ["Desktop", "Documents"];
// A sync client's marker in a folder it syncs.
const syncMarkers = [".dropbox", ".dropbox.cache", ".nextcloudsync.log", ".owncloudsync.log", ".stfolder", ".sync"];
const isSyncMarker = (name) => syncMarkers.includes(name) || /^\.sync_.*\.db$/.test(name);
const sharedTemporary = ["/tmp", "/var/tmp", "/dev/shm", "/private/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"];
const ciWorkspaces = ["GITHUB_WORKSPACE", "RUNNER_WORKSPACE", "RUNNER_TEMP"];

// A path in one form: normalized, with no trailing separator.
const clean = (path) => (path === sep ? sep : normalize(path).replace(/(.)\/+$/, "$1"));
const under = (path, dir) => path === dir || path.startsWith(dir === sep ? sep : `${dir}${sep}`);
const unique = (list) => [...new Set(list)];

// `context`: { real, home, teamHome, tmpdir, env, platform, holding, resolved }. `holding` maps each
// real ancestor of the path (itself included) to the names it holds of `.git` and the sync markers,
// nearest first; `resolved` maps a named directory to its real path.
export function destinationRefusal(path, { real = path, home, teamHome, tmpdir: nodeTemp, env = {}, platform, holding = {}, resolved = {} }) {
  const homeForms = home ? unique([clean(home), resolved[home]].filter(Boolean)) : [];
  const show = (dir) => {
    const form = homeForms.find((candidate) => under(dir, candidate));
    if (!form) return dir;
    return dir === form ? "~" : `~/${dir.slice(form.length + 1)}`;
  };
  const at = `the backups folder ${isAbsolute(path) ? show(clean(path)) : path}`;
  if (!isAbsolute(path)) return `${at} is not an absolute path`;
  const paths = unique([clean(path), real]);
  const forms = (dir) => (dir ? unique([clean(dir), resolved[dir]].filter(Boolean)) : []);
  const inside = (dir) => forms(dir).some((form) => paths.some((candidate) => under(candidate, form)));

  if (paths.includes(sep)) return `${at} is / itself`;
  if (homeForms.some((form) => paths.includes(form))) return `${at} is the home directory itself`;

  for (const [dir, names] of Object.entries(holding)) {
    if (names.includes(".git") && inside(dir)) return `${at} is inside a git checkout: ${show(dir)} holds .git`;
  }
  if (teamHome && inside(teamHome)) return `${at} is inside the team home, ${show(clean(teamHome))}`;
  const inHome = (name) => homeForms.some((form) => inside(join(form, name)));
  if (inHome(".claude")) return `${at} is inside ~/.claude, Claude Code's own folder of transcripts and jobs`;
  if (inHome(".no-mistakes")) return `${at} is inside ~/.no-mistakes, the gate's own folder of worktrees`;

  const temporary = unique([...sharedTemporary, nodeTemp, env.TMPDIR, env.XDG_RUNTIME_DIR].filter(Boolean));
  const temp = temporary.find(inside);
  if (temp) return `${at} is inside a shared temporary directory, ${show(clean(temp))}`;

  if (home) {
    const synced = [...syncedUnderHome, ...(platform === "darwin" ? syncedOnMac : [])].find(inHome);
    if (synced) return `${at} is inside a synced folder, ~/${synced}`;
    // OneDrive for a work or school account: ~/OneDrive - <organisation>.
    for (const form of homeForms) {
      for (const candidate of paths.filter((one) => one !== form && under(one, form))) {
        const first = candidate.slice(form.length + 1).split(sep)[0];
        if (first.startsWith("OneDrive - ")) return `${at} is inside a synced folder, ~/${first}`;
      }
    }
  }
  for (const [dir, names] of Object.entries(holding)) {
    const marker = names.find(isSyncMarker);
    if (marker && inside(dir)) return `${at} is inside a synced folder: ${show(dir)} holds ${marker}`;
  }

  for (const name of ciWorkspaces) {
    if (env[name] && inside(env[name])) return `${at} is inside a CI workspace, ${name} (${show(clean(env[name]))})`;
  }
  return undefined;
}

export function realPathOf(path) {
  let current = resolve(path);
  const rest = [];
  let links = 0;
  for (;;) {
    try {
      return join(realpathSync(current), ...rest);
    } catch (error) {
      if (!["ENOENT", "ENOTDIR"].includes(error.code)) throw error;
    }
    let link = null;
    try {
      if (lstatSync(current).isSymbolicLink()) link = readlinkSync(current);
    } catch {
      // Not there at all: go up.
    }
    if (link !== null) {
      // A symlink to what does not exist yet: follow it.
      links += 1;
      if (links > 40) throw new Refusal(`${path} has too many symlinks to follow`);
      current = resolve(dirname(current), link);
      continue;
    }
    if (current === dirname(current)) return join(current, ...rest);
    rest.unshift(basename(current));
    current = dirname(current);
  }
}

// The team home as bin/lib/team.sh finds it: TEAM_HOME, else the first line of
// ~/.config/agent-team/home, relative to the home unless it is absolute.
function teamHomeOf(home, env) {
  if (env.TEAM_HOME) return env.TEAM_HOME;
  try {
    const line = readFileSync(join(home, ".config", "agent-team", "home"), "utf8").split("\n")[0];
    if (!line) return undefined;
    return isAbsolute(line) ? line : join(home, line);
  } catch {
    return undefined;
  }
}

function holdingOf(dir) {
  let names;
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  return names.filter((name) => name === ".git" || isSyncMarker(name)).sort();
}

export function rootContext(path, { env = process.env, platform = process.platform } = {}) {
  const real = realPathOf(path);
  const home = homedir();
  const teamHome = teamHomeOf(home, env);
  const nodeTemp = tmpdir();
  const holding = {};
  for (let dir = real; ; dir = dirname(dir)) {
    if (existsSync(dir)) {
      const names = holdingOf(dir);
      if (names.length) holding[dir] = names;
    }
    if (dir === dirname(dir)) break;
  }
  const named = [home, teamHome, nodeTemp, ...sharedTemporary, env.TMPDIR, env.XDG_RUNTIME_DIR, ...ciWorkspaces.map((name) => env[name])].filter(Boolean);
  const resolved = {};
  for (const dir of named) {
    if (!isAbsolute(dir)) continue;
    const form = realPathOf(dir);
    if (form !== clean(dir)) resolved[dir] = form;
  }
  const pickedEnv = {};
  for (const name of ["TMPDIR", "XDG_RUNTIME_DIR", ...ciWorkspaces]) {
    if (env[name]) pickedEnv[name] = env[name];
  }
  return { real, home, teamHome, tmpdir: nodeTemp, env: pickedEnv, platform, holding, resolved };
}

export function backupsRoot(configured) {
  const home = homedir();
  const root = process.env.PROD_MONGO_ROOT ?? configured.replace(/^~(?=\/)/, home);
  const shown = (path) => (path === home ? "~" : path.startsWith(`${home}/`) ? `~/${path.slice(home.length + 1)}` : path);
  return { root, home, shown };
}

export function checkRoot(root, { create = false, shown = (path) => path } = {}) {
  const context = rootContext(root);
  const refusal = destinationRefusal(root, context);
  if (refusal) throw new Refusal(refusal);
  const { real } = context;
  if (!existsSync(real)) {
    if (!create) return { real, missing: true };
    mkdirSync(real, { recursive: true, mode: 0o700 });
  }
  const stat = statSync(real);
  if (!stat.isDirectory()) throw new Refusal(`${shown(root)} is not a directory`);
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) throw new Refusal(`${shown(root)} belongs to another user`);
  const mode = stat.mode & 0o777;
  if ((mode & 0o077) === 0) return { real };
  chmodSync(real, 0o700);
  return { real, note: `${shown(root)} was mode ${mode.toString(8).padStart(4, "0")}, open to others, so it is now 0700, yours alone.` };
}

export function dumpByStamp(real, stamp, shownRoot) {
  if (typeof stamp !== "string" || !stampPattern.test(stamp)) {
    const given = typeof stamp === "string" ? `"${stamp.slice(0, 40)}${stamp.length > 40 ? "..." : ""}"` : "that";
    throw new Refusal(`${given} is not a backup's name, which is its UTC start, as 2026-11-08T142305Z`);
  }
  const folder = join(real, stamp);
  let stat;
  try {
    stat = lstatSync(folder);
  } catch {
    throw new Refusal(`${shownRoot} holds no backup ${stamp}`);
  }
  if (!stat.isDirectory()) throw new Refusal(`${shownRoot}/${stamp} is not a folder this toolkit took`);
  let manifest;
  try {
    const file = join(folder, "manifest.json");
    if (!lstatSync(file).isFile()) throw new Error("not a file");
    manifest = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    manifest = undefined;
  }
  if (manifest?.verified !== true) throw new Refusal(`${shownRoot}/${stamp} has no verified manifest.json, so it is not a dump this toolkit took`);
  return { stamp, folder, manifest };
}
