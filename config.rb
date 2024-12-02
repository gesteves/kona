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
activate :asset_hash, ignore: [/\.ttf$/]
activate :directory_indexes

ignore "/article.html"
ignore "/articles.html"
ignore "/home.html"
ignore "/javascripts/stimulus/*"
ignore "/page.html"
ignore "/short.html"

@app.data.articles.each do |article|
  proxy article.path, article.template, locals: { content: article }, ignore: true
end

@app.data.pages.each do |page|
  proxy page.path, page.template, locals: { content: page }, ignore: true
end

@app.data.tags.each do |tag|
  tag.pages.each do |page|
    proxy page.path, page.template, locals: { content: page }, ignore: true
  end
end

@app.data.blog.each do |page|
  proxy page.path, page.template, locals: { content: page }, ignore: true
end

configure :development do
  activate :relative_assets
end

configure :production do
  activate :minify_css
  activate :minify_html

  page "/404.html", directory_index: false
end
