// Build script for the admin bundle. A config file rather than CLI flags (as web/ uses) because
// the Sass plugin has to be registered in-process.
//
// One entrypoint produces two outputs: app/assets/builds/admin.js and, from the stylesheet imports
// in admin.js, a sibling admin.css. Propshaft fingerprints both.
//
// ⚠️ esbuild — not Sass — is what flattens Web Awesome's stylesheet. `webawesome.css` is a chain of
// `@import url(...)` statements, and Sass emits those through as plain CSS imports rather than
// inlining them, which would leave the built file pointing at paths that don't exist.
import esbuild from "esbuild";
import { sassPlugin } from "esbuild-sass-plugin";

const watch = process.argv.includes("--watch");

const context = await esbuild.context({
  entryPoints: ["app/javascript/admin.js"],
  bundle: true,
  outdir: "app/assets/builds",
  publicPath: "/assets",
  // ⚠️ es2022: the source uses Object.hasOwn and replaceAll, which esbuild never rewrites.
  target: "es2022",
  minify: !watch,
  sourcemap: watch,
  logLevel: "info",
  plugins: [ sassPlugin({ type: "css", loadPaths: [ "node_modules" ] }) ]
});

if (watch) {
  // The watcher holds the event loop open, so the process stays up until overmind signals it —
  // no equivalent of esbuild's `--watch=forever` flag is needed here.
  await context.watch();
} else {
  await context.rebuild();
  await context.dispose();
}
