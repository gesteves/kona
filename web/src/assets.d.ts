// The binary modules that src/og-render.ts imports. wrangler changes each one into a true Worker
// module: a `.wasm` file through its default CompiledWasm rule, and a `.ttf` or `.png` file through
// the `rules` entry in wrangler.jsonc. tsc knows neither of those, thus these declarations are what
// make the types correct. Their shapes are the same as the output of `wrangler types` for those two
// module types.
//
// ⚠️ These are not in src/env.d.ts, thus tsconfig.test.json can include this file and not the Worker
// global declarations beside it. The test configuration loads @cloudflare/workers-types, which
// conflicts with those declarations, but not with an ambient module declaration. The test
// configuration needs these, because test/og.test.ts imports src/og.ts, and the dynamic import() in
// that file brings og-render.ts into the program, although the test never runs it.
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
