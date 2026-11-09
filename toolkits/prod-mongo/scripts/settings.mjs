// The prod-mongo toolkit's settings, the one place they are written: the server's name, the
// 1Password reference of the read user's connection string, the one database every tool works on,
// and the backups folder, written from ~/. start-server.mjs, which alone reads 1Password, and the
// container scripts, which read no credential, all take them from here.
export const settings = {
  name: "prod-mongo",
  reference: "op://agent-team/conventioner-prod-read/uri",
  database: "conventioner",
  root: "~/conventioner-backups",
};
