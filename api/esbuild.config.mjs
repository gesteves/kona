// The build script of the admin bundle. It is a file and not a set of CLI flags, as web/ uses,
// because the Sass plugin must register in the process.
//
// One entry point gives two files: app/assets/builds/admin.js and, from the stylesheet imports
// in admin.js, admin.css beside it. Propshaft adds a fingerprint to each one.
//
// ⚠️ esbuild flattens the stylesheet of Web Awesome, and Sass does not. `webawesome.css` is a
// chain of `@import url(...)` statements, and Sass writes each one out as a plain CSS import.
// Thus an import of that file from the Sass would leave paths that do not exist in admin.css.
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
  // The watcher keeps the event loop open, thus the process stays up until overmind stops it.
  // It needs no equivalent of the `--watch=forever` flag of esbuild.
  await context.watch();
} else {
  await context.rebuild();
  await context.dispose();
}
