// What a mongodump directory dump (--gzip) of one database holds, read without decoding a
// document: each collection's document count from its .bson.gz stream, and its type and index
// names from its .metadata.json.gz.
//
//   await readDump(dir)      Map of collection name to { type, documents, indexes, bytes }, read
//                            from <dir>, the dump's database directory (<out>/<database>);
//                            `documents` is null for a view, which mongodump dumps as metadata only
//   await countBsonGz(path)  the documents in a gzipped BSON file: a sequence of documents, each
//                            starting with its little-endian 32-bit length
//   humanBytes(n), duration(ms), count(n)   the answers' forms of a size, a time and a number
import { createReadStream, existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import { createGunzip, gunzipSync } from "node:zlib";

const metadataSuffix = ".metadata.json.gz";

export async function readDump(dir) {
  const collections = new Map();
  const files = existsSync(dir) ? readdirSync(dir) : [];
  for (const file of files.filter((name) => name.endsWith(metadataSuffix))) {
    const base = file.slice(0, -metadataSuffix.length);
    const metadataPath = join(dir, file);
    const metadata = JSON.parse(gunzipSync(readFileSync(metadataPath)).toString("utf8"));
    // mongodump escapes a name it cannot use as a file name; the metadata holds it as it is.
    const name = metadata.collectionName ?? base;
    const type = metadata.type === "view" ? "view" : "collection";
    const bsonPath = join(dir, `${base}.bson.gz`);
    const hasBson = existsSync(bsonPath);
    collections.set(name, {
      type,
      documents: type === "view" ? null : hasBson ? await countBsonGz(bsonPath) : undefined,
      indexes: (metadata.indexes ?? []).map((index) => index.name).sort(),
      bytes: statSync(metadataPath).size + (hasBson ? statSync(bsonPath).size : 0),
    });
  }
  return collections;
}

export async function countBsonGz(path) {
  let documents = 0;
  let skip = 0;
  let header = Buffer.alloc(0);
  await pipeline(createReadStream(path), createGunzip(), async (source) => {
    for await (const chunk of source) {
      let at = 0;
      while (at < chunk.length) {
        if (skip > 0) {
          const step = Math.min(skip, chunk.length - at);
          skip -= step;
          at += step;
          continue;
        }
        const take = chunk.subarray(at, at + 4 - header.length);
        header = Buffer.concat([header, take]);
        at += take.length;
        if (header.length < 4) continue;
        const length = header.readInt32LE(0);
        if (length < 5) throw new Error(`${path} is not a BSON stream`);
        skip = length - 4;
        header = Buffer.alloc(0);
        documents += 1;
      }
    }
  });
  if (skip > 0 || header.length > 0) throw new Error(`${path} ends inside a document`);
  return documents;
}

export function humanBytes(bytes) {
  const units = ["KiB", "MiB", "GiB", "TiB"];
  if (bytes < 1024) return `${bytes} B`;
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
}

export function duration(ms) {
  const seconds = Math.round(ms / 1000);
  if (seconds < 60) return `${seconds} s`;
  return `${Math.floor(seconds / 60)} min ${seconds % 60} s`;
}

export const count = (n) => n.toLocaleString("en-US");
