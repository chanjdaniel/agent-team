// get-uri's ftp:// fetch, which mongodb-mcp-server's proxy support (devtools-proxy-support, then
// pac-proxy-agent) uses for a PAC file at an ftp:// URL, run against the basic-ftp that
// servers/package.json overrides get-uri's ^5 with (6.x; tests/repo.bats holds the lock to a
// release without the listing-parser issue). A minimal FTP server on the loopback answers it: the
// modified date by MDTM, by an MLSD listing when MDTM is not implemented, and a missing file.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { createServer } from "node:net";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { repoRoot } from "./helpers/mcp.mjs";

// get-uri and basic-ftp as pac-proxy-agent resolves them from devtools-proxy-support's install.
const fromProxySupport = createRequire(join(repoRoot, "servers/node_modules/@mongodb-js/devtools-proxy-support/package.json"));
const fromPacAgent = createRequire(fromProxySupport.resolve("pac-proxy-agent"));
const { getUri } = fromPacAgent("get-uri");
const fromGetUri = createRequire(fromPacAgent.resolve("get-uri"));
const basicFtpVersion = fromGetUri("basic-ftp/package.json").version;

const pac = 'function FindProxyForURL(url, host) { return "DIRECT"; }\n';
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
          assert.equal(arg, "/pac");
          send("type=file;size=58;modify=20261031120000; proxy.pac\r\ntype=dir;modify=20261030000000; old\r\n");
          break;
        case "RETR":
          assert.equal(arg, "/pac/proxy.pac");
          send(pac);
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

const fetchPac = async (mode) => {
  mdtm = mode;
  commands.length = 0;
  return getUri(`${base}/pac/proxy.pac`);
};

test("get-uri runs on a basic-ftp without the listing-parser issue", () => {
  const [major, minor, patch] = basicFtpVersion.split(".").map(Number);
  assert.ok(major > 6 || (major === 6 && (minor > 2 || (minor === 2 && patch >= 1))), `basic-ftp ${basicFtpVersion}`);
});

test("get-uri fetches a file over ftp:// with its MDTM date", async () => {
  const stream = await fetchPac("date");
  assert.equal(await read(stream), pac);
  assert.equal(+stream.lastModified, +modified);
  assert.ok(commands.includes("MDTM /pac/proxy.pac"));
  assert.ok(commands.includes("RETR /pac/proxy.pac"));
});

test("get-uri takes the date from an MLSD listing when the server has no MDTM", async () => {
  const stream = await fetchPac("unimplemented");
  assert.equal(await read(stream), pac);
  assert.equal(+stream.lastModified, +modified);
  assert.ok(commands.includes("MLSD /pac"));
});

test("get-uri reports a file the server does not have as not found", async () => {
  await assert.rejects(fetchPac("missing"), { code: "ENOTFOUND" });
  assert.ok(!commands.some((line) => line.startsWith("RETR")));
});
