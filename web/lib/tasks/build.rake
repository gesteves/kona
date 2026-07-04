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
  File.rename("#{BUILD_DIRECTORY}/redirects", "#{BUILD_DIRECTORY}/_redirects")
  sh 'npm run pagefind'
end
