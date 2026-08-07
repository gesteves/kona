// Binary modules imported by src/og-render.ts. wrangler turns these into real Worker modules —
// `.wasm` via its default CompiledWasm rule, `.ttf`/`.png` via the `rules` entry in
// wrangler.jsonc — but tsc knows nothing about either, so these declarations are what make them
// typecheck. The shapes match what `wrangler types` emits for those two module types.
//
// ⚠️ Kept out of src/env.d.ts so tsconfig.test.json can include this file without the Worker
// global shims next to it. The test config pulls in @cloudflare/workers-types, which collides
// with those shims — but not with ambient module declarations. It needs these because
// test/og.test.ts imports src/og.ts, whose dynamic import() drags og-render.ts into the program
// even though the test never executes it.
declare module '*.wasm' {
  const value: WebAssembly.Module;
  export default value;
}

declare module '*.ttf' {
  const value: ArrayBuffer;
  export default value;
}

declare module '*.png' {
  const value: ArrayBuffer;
  export default value;
}
