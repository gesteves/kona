# Kona

A massively-overengineered blogging system behind _[Given to Tri](https://www.giventotri.com/)_, built on [Middleman](https://middlemanapp.com/), powered by [Contentful](https://www.contentful.com/), and hosted on [Netlify](https://www.netlify.com/).

Kona consists of three separate apps:

- **`web/`** — the blog itself: a Middleman static site powered by Contentful and hosted on Netlify.
- **`api/`** — a small Rails API, deployed to fly.io, that serves live, embeddable widgets (weather, activity stats, Whoop, etc.) into the otherwise-static site.
- **`og/`** — a tiny Node service, deployed to fly.io, that renders the Open Graph card images (`og:image` for pages without a cover image) on demand.

Instructions for setting up each app are in their corresponding READMEs: [`web/README.md`](web/README.md), [`api/README.md`](api/README.md), and [`og/README.md`](og/README.md).
