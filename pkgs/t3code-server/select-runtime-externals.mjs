// Prints the server dependencies upstream's CLI archive installs beside the bundle,
// using the release's own selection code so the set follows each T3 Code version.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [src] = process.argv.slice(2);
const { selectCliRuntimeExternalDependencies } = await import(
  pathToFileURL(join(src, "scripts/lib/cli-external-packages.ts")).href
);
const { dependencies } = JSON.parse(await readFile(join(src, "apps/server/package.json"), "utf8"));

console.log(Object.keys(selectCliRuntimeExternalDependencies(dependencies)).sort().join("\n"));
