require_relative "lib/helpers"

each_kona_helper { |helper| helpers helper }

config[:css_dir]             = 'stylesheets'
config[:js_dir]              = 'javascripts'
config[:images_dir]          = 'images'

# esbuild puts the Stimulus and Turbo JavaScript, and the Web Awesome CSS that it imports, into
# tmp/dist. Middleman reads that directory as if it were source/, thus asset_hash applies. The
# development server runs the watcher itself, thus you need no separate `npm run watch` terminal.
# The watcher needs --watch=forever: Middleman starts it with no stdin, and a plain --watch stops
# when stdin closes.
activate :external_pipeline,
  name: :esbuild,
  command: build? ? 'npm run build' : 'npm run watch',
  source: 'tmp/dist',
  latency: 1

# `activate :gzip` is off, on purpose: Cloudflare compresses each response itself, thus nothing
# serves the .gz files and they only add files to the Worker asset upload.
# ⚠️ Autoprefixer is off, on purpose. Its caniuse data stops at Safari 15.4, thus a browserslist
# query writes the IE 11 `-ms-grid-*` properties into a subgrid layout, or it matches no version.
# A person writes the two necessary prefixes by hand. Refer to _nav.scss and base/_extends.scss.
activate :dotenv
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
ignore "/about_md.txt"
ignore "/entry_md.txt"

# Each article, each page, the blog index, and each tag page proxies its template, with itself as
# the `content` local.
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

# Each published post also gets a Markdown copy at "<permalink>index.md". A zone rewrite rule sends
# each request with `Accept: text/markdown` to it. It uses a `.txt.erb` template for the same reason
# as about.md below.
@app.data.articles.reject(&:draft).each do |content|
  proxy EntryMarkdownHelpers.markdown_path(content.path), "/entry_md.txt", locals: { content: content },
    layout: false, directory_index: false, content_type: "text/markdown; charset=utf-8", ignore: true
end

# Each tag also gets an Atom feed at "<tag path>feed.xml". It lists the entries of that tag, which
# are the same articles as on its archive page, with the newest first.
@app.data.tags.each do |tag|
  proxy TaxonomyHelpers.tag_feed_path(tag.tag.path), "/tag_feed.xml", locals: { content: tag }, ignore: true
end

# The standard.site verification endpoint.
page "/.well-known/site.standard.publication", layout: false, directory_index: false

# `_headers` gives the Content-Type in production. This gives it to `middleman server`.
page "/llms.txt", layout: false, directory_index: false, content_type: "text/plain; charset=utf-8"

# The about page as AboutSpec Markdown. ⚠️ This is a proxy to a `.txt.erb` template, and not a
# source file named `about.md.erb`. Middleman reads `.md` as a template extension and would render
# that file into HTML.
# `_headers` gives the Content-Type in production. `content_type` gives it to `middleman server`,
# which otherwise sends `text/plain` with no charset, and the browser then shows UTF-8 as Latin-1.
if (about_page = AboutHelpers.about_page(@app.data.pages))
  proxy "/.well-known/about.md", "/about_md.txt", locals: { content: about_page }, layout: false,
    directory_index: false, content_type: "text/markdown; charset=utf-8", ignore: true
end

# ⚠️ This reads each blurhash placeholder from Redis one time, in the parent, before the build
# forks. Refer to BlurhashHelpers#blurhash_jpeg_data_uri for the reason.
before_build do |_builder|
  require_relative "lib/utils/redis_connection"
  found = BlurhashHelpers.warm_blurhashes!(app.data.assets, RedisConnection.connection)
  puts "== Blurhash placeholders: #{found} of #{app.data.assets.size} from the cache"
rescue StandardError => e
  puts "== Blurhash placeholders: not warmed (#{e.class}: #{e.message})"
end

configure :development do
  activate :relative_assets

  # In production, /widgets/* and /api/contact are Worker routes. Thus the development server has no
  # page at those paths and each widget goes away. This code replaces the proxy of the Worker.
  require_relative "lib/utils/dev_api_proxy"
  use DevApiProxy
end

configure :production do
  activate :minify_css
  activate :minify_html

  page "/404.html", directory_index: false
end
