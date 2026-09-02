require_relative "lib/helpers"

each_kona_helper { |helper| helpers helper }

# Start and configure the extensions.
# https://middlemanapp.com/advanced/configuration/#configuring-extensions

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
# serves the .gz files and they only add approximately 110 files to the Worker asset upload.
# ⚠️ Autoprefixer is off, on purpose. Its caniuse data stops at Safari 15.4, thus each browserslist
# query is incorrect (it targets 2022 and writes the IE 11 `-ms-grid-*` properties into a subgrid
# layout) or it matches no known version. Only two prefixes are still necessary, and a person writes
# both of them beside the `@supports` condition that names them. Refer to _nav.scss and
# base/_extends.scss.
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

# Each page that the build makes — an article, a page, the blog index, and a tag page — proxies its
# template with itself as the `content` local.
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

# Each tag also gets an Atom feed at "<tag path>feed.xml". It lists the entries of that tag, which
# are the same articles as on its archive page, with the newest first.
@app.data.tags.each do |tag|
  proxy "#{tag.tag.path}feed.xml", "/tag_feed.xml", locals: { content: tag }, ignore: true
end

# The standard.site verification endpoint. It has no layout and no directory index.
page "/.well-known/site.standard.publication", layout: false, directory_index: false

# ⚠️ The build renders in forked workers, and a memo in a helper is copied into each one. This reads
# each blurhash placeholder from Redis one time, here in the parent, and the forks inherit the
# result. Refer to ImageHelpers#blurhash_jpeg_data_uri.
before_build do |_builder|
  require_relative "lib/utils/redis_connection"
  found = ImageHelpers.warm_blurhashes!(app.data.assets, RedisConnection.connection)
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
