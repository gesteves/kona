import satori, { init as initYoga } from 'satori/standalone';
import { Resvg, initWasm } from '@resvg/resvg-wasm';
// Both are CompiledWasm modules — wrangler's DEFAULT module rules already cover `**/*.wasm`, so
// unlike the font and logo below they need no `rules` entry in wrangler.jsonc. The import yields
// an ALREADY-COMPILED WebAssembly.Module, which is the whole reason this works on Workers at all:
// the runtime forbids compiling wasm from bytes (`new WebAssembly.Module(...)`), which is exactly
// what @vercel/og does and why it can't run here. Both libraries' init paths accept a Module and
// go to WebAssembly.instantiate(module, imports), which is permitted.
// (Both typecheck against the `declare module '*.wasm'` shim in src/env.d.ts.)
import yogaWasm from 'satori/yoga.wasm';
import resvgWasm from '@resvg/resvg-wasm/index_bg.wasm';
// Data modules (ArrayBuffer) — these DO need the `rules` entry in wrangler.jsonc.
import fontData from './assets/IBMPlexSansCondensed-Bold.ttf';
import logoPng from './assets/logo.png';

// The Open Graph card renderer: satori lays the card out as SVG, resvg rasterizes it to PNG.
// Ported from the retired kona-og fly service (og/render.mjs on the `restore-og` branch), which
// used @vercel/og — itself a wrapper around these same two libraries. The element tree,
// dimensions, font, and colors are carried over verbatim so revived cards render identically to
// the ones this replaces.
//
// ⚠️ This module is deliberately NOT imported at the top of src/og.ts. It's reached through a
// dynamic import() behind the RenderCard seam, so a /widgets, /api/contact or /pa request never
// evaluates satori's ~240 KB of module-scope code — and so the test suite can exercise the whole
// route handler without loading it (the vitest pool cannot load Data modules; see test/og.test.ts
// and web/CLAUDE.md).

const WIDTH = 1200;
const HEIGHT = 630;

// satori reads nothing from an element but `type` and `props`, so React's createElement is pure
// overhead here — this is the entire replacement. (og/render.mjs imported React solely for this.)
type Element = { type: string; props: Record<string, unknown> };

function h(
  type: string,
  props: Record<string, unknown>,
  children?: unknown
): Element {
  return { type, props: { ...props, children } };
}

// Inlined once at module scope rather than fetched per render. It must stay a PNG: satori decodes
// only PNG and JPEG (a webp/avif source fails with an unhelpful error), and the logo's
// transparency has to survive. To change it, replace src/assets/logo.png and bump
// OG_TEMPLATE_VERSION in web/lib/helpers/image_helpers.rb, which re-mints every card URL.
function base64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  // Chunked: String.fromCharCode(...bytes) on a 20 KB array is fine, but the spread would blow
  // the call stack on a larger asset, and this is the kind of thing that only breaks later.
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

const logoDataUri = `data:image/png;base64,${base64(logoPng)}`;

// ⚠️ Style props only — never satori's `tw` shorthand. The tailwind code path reads
// `process.env.JEST_WORKER_ID` unguarded, and `process` is undefined in Workers without
// nodejs_compat, so a single `tw` prop would throw at render time.
function cardElement(title: string): Element {
  return h(
    'div',
    {
      style: {
        alignItems: 'center',
        backgroundColor: '#FFF',
        display: 'flex',
        flexFlow: 'column',
        height: `${HEIGHT}px`,
        justifyContent: 'center',
        position: 'relative',
        width: `${WIDTH}px`,
      },
    },
    [
      h('img', {
        src: logoDataUri,
        style: { margin: '1rem 0', width: '200px' },
      }),
      h(
        'h1',
        {
          style: {
            background: 'linear-gradient(180deg, #0F3557 0%, #030B11 100%)',
            backgroundClip: 'text',
            borderTop: '1px solid #EBEBEB',
            color: 'transparent',
            fontFamily: 'IBM Plex Sans Condensed',
            fontSize: '72px',
            margin: '1rem',
            padding: '1rem',
            position: 'relative',
            textAlign: 'center',
            textWrap: 'balance',
          },
        },
        title
      ),
    ]
  );
}

let ready: Promise<void> | undefined;

// ⚠️ A memoized PROMISE, not a boolean flag. resvg's own guard sets its `initialized` flag only
// AFTER awaiting the wasm load, so two requests arriving before the first one finishes both get
// past it and the second throws "Already initialized. The `initWasm()` function can be used only
// once." — permanently poisoning that isolate. Every caller awaiting one promise is what makes
// the first render concurrency-safe.
function init(): Promise<void> {
  ready ??= (async () => {
    await Promise.all([initYoga(yogaWasm), initWasm(resvgWasm)]);
  })();
  return ready;
}

// Renders a 1200×630 PNG for the given title and returns its bytes.
export async function renderCard(
  title: string
): Promise<Uint8Array<ArrayBuffer>> {
  await init();

  const svg = await satori(cardElement(title) as never, {
    width: WIDTH,
    height: HEIGHT,
    fonts: [
      {
        name: 'IBM Plex Sans Condensed',
        data: fontData,
        weight: 700,
        style: 'normal',
      },
    ],
  });

  // satori embeds the font as vector paths (embedFont defaults to true), so resvg needs no font
  // database of its own. fitTo matches what @vercel/og passed, so output dimensions are unchanged.
  const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: WIDTH } });
  const rendered = resvg.render();
  // asPng() is typed as a bare Uint8Array, i.e. ArrayBufferLike-backed, which a Response body
  // won't accept (it can't be a SharedArrayBuffer). wasm-bindgen copies the bytes out of the
  // linear heap into a fresh ArrayBuffer, so narrowing here is safe and keeps the cast next to
  // the fact that justifies it rather than at the call site.
  const png = rendered.asPng() as Uint8Array<ArrayBuffer>;
  // ⚠️ Both hold allocations in the wasm linear heap, which is NOT garbage-collected by the JS
  // GC. A Worker isolate is long-lived and serves many renders, so skipping these leaks memory
  // until the isolate is evicted — eventually hitting the 128 MB limit mid-render.
  rendered.free();
  resvg.free();

  return png;
}
