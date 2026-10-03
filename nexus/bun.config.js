import path from 'path';
import fs from 'fs';

const outdir = path.join(process.cwd(), "app/assets/builds");
// The dev loop is `bun run build --watch` (Procfile.dev); everything else —
// `bin/rails assets:precompile`, `test:prepare`, the image build — is a
// one-shot build whose output SHIPS.
const watching = process.argv.includes('--watch');

// MINIFIED ALWAYS, MAPPED ONLY WHILE WATCHING. Propshaft digests every file
// under app/assets/builds and the image precompiles there, so whatever this
// writes is what production serves: an unminified bundle plus its sourcemap
// were 818 KB of assets for 312 lines of our own JavaScript, and the css
// build next to it has passed `--minify` all along. The watch build keeps the
// map, because it is the one a person debugs, and skips the minifier that
// would make it unreadable anyway.
//
// `linked`, NOT `external`: both write the .map, but `external` ends the
// bundle with a bare `//# debugId=` and no `sourceMappingURL`, so no debugger
// ever loads it — a sourcemap kept for the person debugging that the person
// debugging cannot see. `linked` emits the comment, and propshaft's
// SourceMappingUrls compiler rewrites it to the digested path.
//
// One directory, two writers: a `bin/rails test` or `assets:precompile` run
// while `bin/dev` is up leaves the minified, mapless bundle behind, and the
// watcher only notices the NEXT source edit. Touch a file under
// app/javascript to get the dev bundle back.
const config = {
  entrypoints: ["app/javascript/application.js"],
  outdir,
  minify: !watching,
  sourcemap: watching ? "linked" : "none",
};

// A map left behind by an earlier watch run would still be digested by a
// local precompile. The image never sees one (.dockerignore excludes this
// directory), but a developer's machine would.
const dropStaleSourcemaps = () => {
  if (!fs.existsSync(outdir)) return;

  for (const entry of fs.readdirSync(outdir)) {
    if (entry.endsWith(".map")) fs.rmSync(path.join(outdir, entry));
  }
};

const build = async (config) => {
  const result = await Bun.build(config);

  if (!result.success) {
    if (process.argv.includes('--watch')) {
      console.error("Build failed");
      for (const message of result.logs) {
        console.error(message);
      }
      return;
    } else {
      throw new AggregateError(result.logs, "Build failed");
    }
  }
};

(async () => {
  if (!watching) dropStaleSourcemaps();
  await build(config);

  if (watching) {
    fs.watch(path.join(process.cwd(), "app/javascript"), { recursive: true }, (eventType, filename) => {
      console.log(`File changed: ${filename}. Rebuilding...`);
      build(config);
    });
  } else {
    process.exit(0);
  }
})();
