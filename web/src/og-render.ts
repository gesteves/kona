import satori, { init as initYoga } from 'satori/standalone';
import { Resvg, initWasm } from '@resvg/resvg-wasm';
// Wasm imports yield an already-compiled WebAssembly.Module, which is why this works on Workers
// at all: the runtime forbids compiling wasm from bytes. Covered by wrangler's default module
// rules and typed by the shim in src/env.d.ts.
import yogaWasm from 'satori/yoga.wasm';
import resvgWasm from '@resvg/resvg-wasm/index_bg.wasm';
// Data modules (ArrayBuffer) — these need the `rules` entry in wrangler.jsonc.
import fontData from './assets/IBMPlexSansCondensed-Bold.ttf';
import logoPng from './assets/logo.png';

// The Open Graph card renderer: satori lays the card out as SVG, resvg rasterizes it to PNG.
//
// Deliberately not imported at the top of src/og.ts — it's reached through a dynamic import()
// behind the RenderCard seam, so other routes never evaluate satori's module-scope code and the
// test suite can exercise the route without loading the Data modules (see web/CLAUDE.md).

const WIDTH = 1200;
const HEIGHT = 630;

/** satori reads only `type` and `props`, so this replaces React's createElement. */
type Element = { type: string; props: Record<string, unknown> };

function h(
  type: string,
  props: Record<string, unknown>,
  children?: unknown
): Element {
  return { type, props: { ...props, children } };
}

/** Base64-encodes an ArrayBuffer, chunked so the spread can't blow the call stack. */
function base64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

// Inlined once at module scope. Must stay a PNG: satori decodes only PNG and JPEG. To change
// it, replace src/assets/logo.png and bump OG_TEMPLATE_VERSION in lib/helpers/image_helpers.rb.
const logoDataUri = `data:image/png;base64,${base64(logoPng)}`;

/**
 * Builds the card's element tree.
 * Style props only — satori's `tw` shorthand reads `process.env` unguarded and throws in Workers.
 */
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

/**
 * Initializes both wasm modules, once per isolate.
 * Memoizes a promise rather than a boolean: resvg sets its own flag only after awaiting the
 * load, so concurrent first requests would both get past it and the second would throw
 * "Already initialized", permanently poisoning the isolate.
 */
function init(): Promise<void> {
  ready ??= (async () => {
    await Promise.all([initYoga(yogaWasm), initWasm(resvgWasm)]);
  })();
  return ready;
}

/**
 * Renders the OG card for a title.
 * @returns The bytes of a 1200×630 PNG.
 */
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

  // satori embeds the font as vector paths, so resvg needs no font database of its own.
  const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: WIDTH } });
  const rendered = resvg.render();
  // asPng() is typed ArrayBufferLike-backed, which a Response body won't accept. wasm-bindgen
  // copies the bytes into a fresh ArrayBuffer, so narrowing is safe.
  const png = rendered.asPng() as Uint8Array<ArrayBuffer>;
  // The wasm linear heap isn't reached by the JS GC, so both must be freed explicitly or a
  // long-lived isolate leaks until it hits the memory limit mid-render.
  rendered.free();
  resvg.free();

  return png;
}
