// The binary modules that src/og-render.ts imports. wrangler makes each one a Worker module: a
// `.wasm` file through its default CompiledWasm rule, and a `.ttf` or `.png` file through the
// `rules` entry in wrangler.jsonc. tsc knows neither rule, thus these declarations give the types.
// Their shapes are the same as the output of `wrangler types`.
//
// ⚠️ These are not in src/env.d.ts, thus tsconfig.test.json can include this file and not the
// Worker global declarations, which conflict with @cloudflare/workers-types. The test compile
// needs these: test/og.test.ts imports src/og.ts, and its dynamic import() brings og-render.ts in.
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
