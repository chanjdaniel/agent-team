// get-uri's ftp:// fetch, as mongodb-mcp-server's proxy support installs it, run against the
// basic-ftp that servers/package.json's overrides puts in place of get-uri's ^5 (6.x, a major
// update; tests/repo.bats holds the lock to 6.2.1 or later). A minimal FTP server on the loopback
// answers it: the modified date by MDTM, by an MLSD listing when MDTM is not implemented, and a
// missing file.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { repoRoot } from "./helpers/mcp.mjs";

// get-uri and basic-ftp as they resolve under devtools-proxy-support's install.
const fromProxySupport = createRequire(join(repoRoot, "servers/node_modules/@mongodb-js/devtools-proxy-support/package.json"));
const fromProxyAgent = createRequire(fromProxySupport.resolve("pac-proxy-agent"));
const { getUri } = fromProxyAgent("get-uri");
const fromGetUri = createRequire(fromProxyAgent.resolve("get-uri"));
const basicFtpVersion = fromGetUri("basic-ftp/package.json").version;

const body = "fixture file\n";
const modified = new Date(Date.UTC(2026, 9, 31, 12, 0, 0));

// mdtm: "date" answers MDTM with the file's date, "unimplemented" with 502 and offers MLSD
// instead, "missing" with 550. Every command each connection sent is kept in `commands`.
let mdtm = "date";
const commands = [];
const sockets = new Set();
const server = createServer((control) => {
  sockets.add(control);
  control.on("close", () => sockets.delete(control));
  control.on("error", () => {});
  let dataSocket;
  const reply = (line) => control.write(`${line}\r\n`);
  // Opens a passive data port; the client connects to it before it sends the transfer command.
  const passive = () =>
    new Promise((resolve) => {
      const data = createServer((socket) => {
        sockets.add(socket);
        socket.on("close", () => sockets.delete(socket));
        socket.on("error", () => {});
        data.close();
        resolve(socket);
      });
      data.listen(0, "127.0.0.1", () => reply(`229 Entering Extended Passive Mode (|||${data.address().port}|)`));
    });
  const send = async (body) => {
    const socket = await dataSocket;
    reply("150 Opening data connection");
    socket.end(body, () => reply("226 Transfer complete"));
  };
  reply("220 test server");
  let buffer = "";
  control.on("data", (chunk) => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf("\r\n")) >= 0) {
      const line = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      commands.push(line);
      const [verb, ...rest] = line.split(" ");
      const arg = rest.join(" ");
      switch (verb) {
        case "USER": reply("331 Password required"); break;
        case "PASS": reply("230 Logged in"); break;
        case "FEAT":
          if (mdtm === "unimplemented") reply("211-Features:\r\n MLST type*;size*;modify*;\r\n211 End");
          else reply("211 No features");
          break;
        case "TYPE": case "STRU": case "OPTS": reply("200 OK"); break;
        case "MDTM":
          if (mdtm === "date") reply("213 20261031120000");
          else if (mdtm === "missing") reply("550 No such file");
          else reply("502 Not implemented");
          break;
        case "EPSV": dataSocket = passive(); break;
        case "MLSD":
          assert.equal(arg, "/pub");
          send("type=file;size=58;modify=20261031120000; file.txt\r\ntype=dir;modify=20261030000000; old\r\n");
          break;
        case "RETR":
          assert.equal(arg, "/pub/file.txt");
          send(body);
          break;
        case "QUIT": reply("221 Bye"); control.end(); break;
        default: reply("502 Not implemented");
      }
    }
  });
});

let base;
before(async () => {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `ftp://127.0.0.1:${server.address().port}`;
});

after(() => {
  for (const socket of sockets) socket.destroy();
  server.close();
});

const read = async (stream) => {
  let text = "";
  for await (const chunk of stream) text += chunk;
  return text;
};

const fetchFile = async (mode) => {
  mdtm = mode;
  commands.length = 0;
  return getUri(`${base}/pub/file.txt`);
};

test("get-uri runs on basic-ftp 6.2.1 or later", () => {
  const [major, minor, patch] = basicFtpVersion.split(".").map(Number);
  assert.ok(major > 6 || (major === 6 && (minor > 2 || (minor === 2 && patch >= 1))), `basic-ftp ${basicFtpVersion}`);
});

test("get-uri fetches a file over ftp:// with its MDTM date", async () => {
  const stream = await fetchFile("date");
  assert.equal(await read(stream), body);
  assert.equal(+stream.lastModified, +modified);
  assert.ok(commands.includes("MDTM /pub/file.txt"));
  assert.ok(commands.includes("RETR /pub/file.txt"));
});

test("get-uri takes the date from an MLSD listing when the server has no MDTM", async () => {
  const stream = await fetchFile("unimplemented");
  assert.equal(await read(stream), body);
  assert.equal(+stream.lastModified, +modified);
  assert.ok(commands.includes("MLSD /pub"));
});

test("get-uri reports a file the server does not have as not found", async () => {
  await assert.rejects(fetchFile("missing"), { code: "ENOTFOUND" });
  assert.ok(!commands.some((line) => line.startsWith("RETR")));
});
