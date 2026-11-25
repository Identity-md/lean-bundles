// Unpacks every bundle with the IMD worker's own reader, the way a machine does before a goal item starts: the released
// worker's `fetchAll` (task/fetch.js), each file served from the build's output folder instead of the release, so a
// bundle the worker would refuse is never published. It checks the size and sha256, unpacks with the worker's reader
// (no member outside the root, no device or pipe, no link out of the archive or to nowhere, within the cache's cap)
// and checks the contents' sha256 that fetch.json names.
//
//   node scripts/worker-unpack.mjs <installed @identitymd/worker folder> <output folder> <scratch home>
import { createReadStream, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, join } from "node:path";
import { Readable } from "node:stream";
import { pathToFileURL } from "node:url";

const [workerDir, outDir, home] = process.argv.slice(2);
if (!workerDir || !outDir || !home) {
  console.error("usage: node scripts/worker-unpack.mjs <worker folder> <output folder> <scratch home>");
  process.exit(2);
}
const { fetchAll } = await import(pathToFileURL(join(workerDir, "dist", "task", "fetch.js")).href);
const specs = JSON.parse(await readFile(join(outDir, "fetch.json"), "utf8"));
const files = new Map(specs.map((spec) => [spec.url, join(outDir, basename(new URL(spec.url).pathname))]));

/** What the release would answer for each of its files, from the output folder; anything else is GitHub's 404. */
const served = async (url) => {
  const file = files.get(String(url));
  if (!file) return new Response(null, { status: 404 });
  return new Response(Readable.toWeb(createReadStream(file)), { status: 200, headers: { "content-length": String(statSync(file).size) } });
};

const started = Date.now();
const got = await fetchAll(specs, { home, fetch: served, resolveHost: async () => ["140.82.112.4"], progress: (line) => console.log(line) });
if (!got.ok) {
  console.error(`::error::the IMD worker refuses this bundle: ${got.reason}`);
  process.exit(1);
}
got.release();
for (const entry of got.fetched) console.log(`${entry.name}: unpacked by the worker into ${entry.dir}`);
console.log(`every bundle unpacked by the worker's own reader in ${Math.round((Date.now() - started) / 1000)} s`);
