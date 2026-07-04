Dir["lib/helpers/*.rb"].each do |file|
  require file
  helpers File.basename(file, ".rb").camelcase.constantize
end

# Activate and configure extensions
# https://middlemanapp.com/advanced/configuration/#configuring-extensions

config[:css_dir]             = 'stylesheets'
config[:js_dir]              = 'javascripts'
config[:images_dir]          = 'images'
activate :gzip
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

# Every generated page — articles, pages, the paginated blog, and the per-tag pages —
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

# Render the standard.site publication verification endpoint as a bare, plain-text
# file at /.well-known/site.standard.publication (no layout, no directory index).
page "/.well-known/site.standard.publication", layout: false, directory_index: false

# Hidden, native replica of the Contentful contact form so Netlify can detect the
# "contact" form (its Web Awesome custom-element fields aren't parseable at build time).
# Served bare at /__forms.html — no layout, no directory index.
page "/__forms.html", layout: false, directory_index: false

configure :development do
  activate :relative_assets
end

configure :production do
  activate :minify_css
  activate :minify_html

  page "/404.html", directory_index: false
end
