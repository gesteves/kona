BUILD_DIRECTORY = 'build'

# Building and testing are separate concerns: `rake build` does NOT run the test suite. Run
# tests with `rake test` (locally, before committing) — in CI they live in the `checks` job,
# which gates deploys on code pushes. Keeping them out of the build means a Contentful-publish
# rebuild (no code changed) isn't slowed by a redundant test run.
desc 'Import content and build the site'
task :build => [:dotenv, :import] do
  build_site
end

namespace :build do
  desc 'Import content and build the site with verbose output'
  task :verbose => [:dotenv, :import] do
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
  sh 'npm run pagefind'
end
