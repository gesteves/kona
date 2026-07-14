BUILD_DIRECTORY = 'build'

desc 'Import content and build the site'
task :build => [:dotenv, :test, :import] do
  build_site
end

namespace :build do
  desc 'Import content and build the site with verbose output'
  task :verbose => [:dotenv, :test, :import] do
    build_site(verbose: true)
  end
end

def build_site(verbose: false)
  verbose = true if ENV['NETLIFY_BUILD_DEBUG'] == 'true'
  # The JS/CSS bundle is built by Middleman's external pipeline (config.rb), which runs
  # `npm run build` itself and blocks until it finishes.
  middleman_command = verbose ? 'middleman build --verbose' : 'middleman build'
  sh middleman_command
  # Underscore-prefixed files in source/ are treated as partials and never built, so the
  # redirects and headers files are authored without the prefix and renamed here.
  File.rename("#{BUILD_DIRECTORY}/redirects", "#{BUILD_DIRECTORY}/_redirects")
  File.rename("#{BUILD_DIRECTORY}/headers", "#{BUILD_DIRECTORY}/_headers")
  # Pre-render the Open Graph card PNGs from the freshly built og/data.json. Redis-cached,
  # so only new/changed titles actually render.
  sh 'node scripts/render-og.mjs'
  sh 'npm run pagefind'
end
