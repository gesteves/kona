import satori, { init as initYoga } from 'satori/standalone';
import { Resvg, initWasm } from '@resvg/resvg-wasm';
// A wasm import gives a WebAssembly.Module that is already compiled, and that is why this works on
// Workers: the runtime does not permit a compile of wasm from bytes. The default module rules of
// wrangler cover this, and the shim in src/env.d.ts gives the types.
import yogaWasm from 'satori/yoga.wasm';
import resvgWasm from '@resvg/resvg-wasm/index_bg.wasm';
// The Data modules (ArrayBuffer). These need the `rules` entry in wrangler.jsonc.
import fontData from './assets/IBMPlexSansCondensed-Bold.ttf';
import logoPng from './assets/logo.png';

// The Open Graph card renderer: satori makes the layout of the card as SVG, and resvg changes that
// SVG into a PNG.
//
// src/og.ts does not import this at the top, on purpose. It reaches this module through a dynamic
// import() behind the RenderCard parameter. Thus the other routes never run the module code of
// satori, and the test suite can run the route and not load the Data modules. Refer to
// web/CLAUDE.md.

const WIDTH = 1200;
const HEIGHT = 630;

/** satori reads only `type` and `props`, thus this replaces the createElement of React. */
type Element = { type: string; props: Record<string, unknown> };

function h(
  type: string,
  props: Record<string, unknown>,
  children?: unknown
): Element {
  return { type, props: { ...props, children } };
}

/** Changes an ArrayBuffer into base64. It uses small parts, thus the spread cannot fill the call
 * stack. */
function base64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

// This is in the module code, one time. It must stay a PNG, because satori decodes only PNG and
// JPEG. To change it, replace src/assets/logo.png and increase OG_TEMPLATE_VERSION in
// lib/helpers/image_helpers.rb.
const logoDataUri = `data:image/png;base64,${base64(logoPng)}`;

/**
 * Makes the element tree of the card.
 * It uses style props only. The `tw` shorthand of satori reads `process.env` with no check and
 * raises in Workers.
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
 * Starts both wasm modules, one time for each isolate.
 * It keeps a promise, and not a boolean. resvg sets its own flag only after it waits for the load.
 * Thus two first requests at the same time would both go past that flag, and the second one would
 * raise "Already initialized" and make the isolate unusable.
 */
function init(): Promise<void> {
  ready ??= (async () => {
    await Promise.all([initYoga(yogaWasm), initWasm(resvgWasm)]);
  })();
  return ready;
}

/**
 * Renders the OG card for a title.
 * @returns The bytes of a PNG of 1200×630.
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

  // satori puts the font in the SVG as vector paths, thus resvg needs no font database.
  const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: WIDTH } });
  const rendered = resvg.render();
  // The type of asPng() is ArrayBufferLike, and a Response body does not accept that type.
  // wasm-bindgen copies the bytes into a new ArrayBuffer, thus a narrower type is correct.
  const png = rendered.asPng() as Uint8Array<ArrayBuffer>;
  // The JS garbage collector does not reach the linear heap of the wasm module. Thus the code must
  // free both, or an isolate that lives a long time uses more and more memory and reaches the
  // memory limit during a render.
  rendered.free();
  resvg.free();

  return png;
}
