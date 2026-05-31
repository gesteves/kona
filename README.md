# Kona

The blogging system behind _[Given to Tri](https://www.giventotri.com/)_, built on [Middleman](https://middlemanapp.com/), powered by [Contentful](https://www.contentful.com/), and hosted on [Netlify](https://www.netlify.com/).

[![Netlify Status](https://api.netlify.com/api/v1/badges/f87f4e00-a5a5-436d-b6df-a3628c3fb919/deploy-status)](https://app.netlify.com/sites/giventotri/deploys)

Kona consists of two separate apps:

- **`web/`** — the blog itself: a Middleman static site powered by Contentful and hosted on Netlify.
- **`api/`** — a small Rails API, deployed to fly.io, that serves live, embeddable widgets (weather, activity stats, Whoop, etc.) into the otherwise-static site through a same-origin Netlify proxy at `/api/*`.

Instructions for setting up each app are in their corresponding READMEs: [`web/README.md`](web/README.md) and [`api/README.md`](api/README.md).
