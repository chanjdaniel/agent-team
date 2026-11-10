// The relay registry trust check of foldkit-devtools-mcp.mjs: @foldkit/devtools-mcp 0.26.0's own
// (dist/relayRegistryTrust.js, relayRegistryTrust.inspect and the functions it calls), ported line
// for line for Linux and macOS, so a registry the server would refuse is never copied into the
// private one it trusts. Port it again when servers/ moves the server to another version.
//
//   registryRefusal(directory)              why the server would refuse it, or null
//   darwinAclOutputRefusal(output, isLeaf)  why macOS's `ls -led` output for one directory of
//                                           the chain refuses it, or null (exported for the test)
import { execFileSync } from "node:child_process";
import { lstatSync, realpathSync } from "node:fs";
import { dirname } from "node:path";

const PERMISSIONS_BEYOND_OWNER = 0o077;
const PARENT_WRITE_PERMISSIONS = 0o022;
const STICKY_DIRECTORY = 0o1000;
const ROOT_UID = 0;
const PROBE_TIMEOUT_MS = 10_000;
const DARWIN_ACL_ENTRY_PATTERN = /^\s*\d+:\s+.+\s(allow|deny)\s+\S+/;
const DARWIN_DIRECTORY_MODE_PATTERN = /^d[rwxstST-]{9}[+@ ]/;
const UNVERIFIED_OWNERSHIP = "has ownership that cannot be verified";
const UNVERIFIED_PERMISSIONS = "has permissions that cannot be verified";
const OWNED_BY_ANOTHER_USER = "is owned by another user";
const SHARED_WITH_OTHER_USERS = "is readable or writable by other users";
const NOT_REGULAR_DIRECTORY = "is not a regular directory";
const REPLACEABLE_PARENT = "has a parent directory that another user can replace";

// The directory and each one above it, the root first.
function directoryChain(directory) {
  const directories = [];
  for (let current = directory; ; current = dirname(current)) {
    directories.push(current);
    if (dirname(current) === current) return directories.reverse();
  }
}

// relayRegistryDirectoryRefusal and posixDirectoryRefusal: the registry itself.
function posixDirectoryRefusal(modeValue, uidValue) {
  const mode = Number(modeValue);
  const uid = Number(uidValue);
  if (!Number.isSafeInteger(mode) || !Number.isSafeInteger(uid)) return UNVERIFIED_OWNERSHIP;
  const currentUid = process.getuid?.();
  if (currentUid === undefined) return UNVERIFIED_OWNERSHIP;
  if (uid !== currentUid) return OWNED_BY_ANOTHER_USER;
  if ((mode & PERMISSIONS_BEYOND_OWNER) !== 0) return SHARED_WITH_OTHER_USERS;
  return null;
}

function posixParentChainRefusal(directory) {
  const currentUid = process.getuid?.();
  if (currentUid === undefined) return UNVERIFIED_OWNERSHIP;
  for (const component of directoryChain(directory)) {
    const entry = lstatSync(component, { bigint: true });
    const uid = Number(entry.uid);
    const mode = Number(entry.mode);
    if (entry.isSymbolicLink() || !entry.isDirectory() || !Number.isSafeInteger(uid) || !Number.isSafeInteger(mode)) {
      return UNVERIFIED_OWNERSHIP;
    }
    if (uid !== currentUid && uid !== ROOT_UID) return REPLACEABLE_PARENT;
    const isParent = component !== directory;
    const isWritableByOtherUsers = (mode & PARENT_WRITE_PERMISSIONS) !== 0;
    const isSticky = (mode & STICKY_DIRECTORY) !== 0;
    if (isParent && isWritableByOtherUsers && !isSticky) return REPLACEABLE_PARENT;
  }
  return null;
}

export function darwinAclOutputRefusal(output, isLeaf) {
  const outputLines = output.split(/\r?\n/);
  const lines = output.endsWith("\n") ? outputLines.slice(0, -1) : outputLines;
  const summary = lines[0];
  if (summary === undefined || !DARWIN_DIRECTORY_MODE_PATTERN.test(summary)) return UNVERIFIED_PERMISSIONS;
  for (const line of lines.slice(1)) {
    const action = DARWIN_ACL_ENTRY_PATTERN.exec(line)?.[1];
    if (action === undefined) return UNVERIFIED_PERMISSIONS;
    if (action === "allow") return isLeaf ? SHARED_WITH_OTHER_USERS : REPLACEABLE_PARENT;
  }
  return null;
}

// Throws when an `ls` fails or times out, which the caller reads as unverified ownership.
function darwinAclChainRefusal(directory) {
  for (const component of directoryChain(directory)) {
    const output = execFileSync("/bin/ls", ["-l", "-d", "-e", "-P", "-b", "--", component], {
      encoding: "utf8",
      env: { ...process.env, LC_ALL: "C" },
      stdio: ["ignore", "pipe", "ignore"],
      timeout: PROBE_TIMEOUT_MS,
    });
    const refusal = darwinAclOutputRefusal(output, component === directory);
    if (refusal !== null) return refusal;
  }
  return null;
}

// The entry at `directory` and at its real path, which must be the same one.
function probeDirectoryEntry(directory) {
  const entry = lstatSync(directory, { bigint: true });
  if (entry.isSymbolicLink() || !entry.isDirectory()) return { directory, entry, refusal: NOT_REGULAR_DIRECTORY };
  const canonicalDirectory = realpathSync(directory);
  const canonicalEntry = lstatSync(canonicalDirectory, { bigint: true });
  const isSameEntry = entry.dev === canonicalEntry.dev && entry.ino === canonicalEntry.ino;
  return { directory: canonicalDirectory, entry: canonicalEntry, refusal: isSameEntry ? null : UNVERIFIED_OWNERSHIP };
}

function inspect(directory) {
  const probe = probeDirectoryEntry(directory);
  if (probe.refusal !== null) return probe.refusal;
  const refusal = posixParentChainRefusal(probe.directory)
    ?? posixDirectoryRefusal(probe.entry.mode, probe.entry.uid)
    ?? (process.platform === "darwin" ? darwinAclChainRefusal(probe.directory) : null);
  if (refusal !== null) return refusal;
  const confirmation = probeDirectoryEntry(directory);
  const isSameDirectory = confirmation.refusal === null
    && confirmation.directory === probe.directory
    && confirmation.entry.dev === probe.entry.dev
    && confirmation.entry.ino === probe.entry.ino;
  return isSameDirectory ? null : UNVERIFIED_OWNERSHIP;
}

export function registryRefusal(directory) {
  try {
    return inspect(directory);
  } catch {
    return UNVERIFIED_OWNERSHIP;
  }
}
