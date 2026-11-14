// The restore drill, as the prod-mongo server runs it and as Daniel or the coordinator may, always
// through the machine's heavy-run lock:
//
//   ~/agent-team/bin/team-heavy run --kind restore-drill -- node ~/agent-team/toolkits/prod-mongo/scripts/restore-drill.mjs <stamp> [--text]
//
// Restores the dump ~/conventioner-backups/<stamp>/ into a throwaway local MongoDB, compares each
// collection's count and index names with its manifest, records the verdict in its drills/ folder
// and removes the throwaway. Prints one JSON object on stdout, or with --text the tool's answer,
// and each step as it starts on stderr; exits 0 on PASS, 1 on FAIL or a refusal, and 128 plus the signal's number when stopped by one.
// Reads no credential and takes no connection string. See servers/prod-mongo/drill.mjs.
import { restoreDrill } from "../../../servers/prod-mongo/drill.mjs";
import { settings } from "./settings.mjs";

await restoreDrill({ argv: process.argv.slice(2), database: settings.database, root: settings.root });
