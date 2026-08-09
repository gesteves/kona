# Kona

A massively overengineered blogging system behind _[Given to Tri](https://www.giventotri.com/)_, built on [Middleman](https://middlemanapp.com/), powered by [Contentful](https://www.contentful.com/), and hosted on [Cloudflare Workers](https://developers.cloudflare.com/workers/).

Kona consists of two separate apps:

- **`web/`** — the blog itself: a Middleman static site powered by Contentful, served by a Cloudflare Worker.
- **`api/`** — a small Rails API, deployed to fly.io, that serves live, embeddable widgets (weather, activity stats, Whoop, etc.) into the otherwise-static site.

Instructions for setting up each app are in their corresponding READMEs: [`web/README.md`](web/README.md) and [`api/README.md`](api/README.md).

Once both are set up, `overmind start` (needs [Overmind](https://github.com/DarthSim/overmind)) runs the whole stack together — the site on `localhost:4567` with its widgets served by the api on `localhost:3000`.
