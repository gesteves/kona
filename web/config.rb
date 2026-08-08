require_relative "lib/helpers"

each_kona_helper { |helper| helpers helper }

# Activate and configure extensions
# https://middlemanapp.com/advanced/configuration/#configuring-extensions

config[:css_dir]             = 'stylesheets'
config[:js_dir]              = 'javascripts'
config[:images_dir]          = 'images'

# esbuild bundles the Stimulus/Turbo JS and the Web Awesome CSS it imports into tmp/dist,
# which Middleman ingests as if it were source/, so asset_hash applies. The dev server runs
# the watcher itself, hence no separate `npm run watch` terminal.
# The watcher needs --watch=forever: Middleman spawns it without stdin, and plain --watch
# exits when stdin closes.
activate :external_pipeline,
  name: :esbuild,
  command: build? ? 'npm run build' : 'npm run watch',
  source: 'tmp/dist',
  latency: 1

# `activate :gzip` is deliberately off: Cloudflare compresses responses itself, so the .gz
# siblings are never served and only add ~110 files to the Worker asset upload.
activate :dotenv
activate :autoprefixer do |config|
  config.browsers = ['last 1 version', 'last 3 safari versions', 'last 3 ios versions']
end
activate :asset_hash
activate :directory_indexes

ignore "/article.html"
ignore "/tag.html"
ignore "/articles.html"
ignore "/home.html"
ignore "/javascripts/stimulus/*"
ignore "/page.html"
ignore "/short.html"
ignore "/tag_feed.xml"

# Every generated page — articles, pages, the blog index, and the per-tag pages —
# proxies its template with itself as the `content` local.
[
  @app.data.articles,
  @app.data.pages,
  @app.data.blog,
  @app.data.tags.flat_map(&:pages)
].each do |collection|
  collection.each do |content|
    proxy content.path, content.template, locals: { content: content }, ignore: true
  end
end

# Each tag also gets an Atom feed at "<tag path>feed.xml", listing that tag's entries — the
# same articles as its archive page, newest first.
@app.data.tags.each do |tag|
  proxy "#{tag.tag.path}feed.xml", "/tag_feed.xml", locals: { content: tag }, ignore: true
end

# The standard.site verification endpoint, served bare: no layout, no directory index.
page "/.well-known/site.standard.publication", layout: false, directory_index: false

configure :development do
  activate :relative_assets
end

configure :production do
  activate :minify_css
  activate :minify_html

  page "/404.html", directory_index: false
end
