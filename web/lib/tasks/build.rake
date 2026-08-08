BUILD_DIRECTORY = "build"

# `rake build` does NOT run the test suite — use `rake test`. Keeping them separate means a
# Contentful-publish rebuild isn't slowed by a redundant test run.
desc "Import content and build the site"
task build: [ :dotenv, :import ] do
  build_site
end

namespace :build do
  desc "Import content and build the site with verbose output"
  task verbose: [ :dotenv, :import ] do
    build_site(verbose: true)
  end

  # Skips :import, so it builds whatever `rake import` last wrote to data/. For refreshing build/
  # during a `wrangler dev` session; `rake build:verbose` is still the pre-commit gate.
  desc "Build the site from the existing data/ without re-importing"
  task fast: [ :dotenv ] do
    build_site
  end
end

# Builds the site. The JS/CSS bundle comes from Middleman's external pipeline, which runs
# `npm run build` itself and blocks until it finishes.
def build_site(verbose: false)
  middleman_command = verbose ? "middleman build --verbose" : "middleman build"
  sh middleman_command
  # Underscore-prefixed files in source/ are treated as partials, so these are authored
  # without the prefix and renamed here.
  File.rename("#{BUILD_DIRECTORY}/redirects", "#{BUILD_DIRECTORY}/_redirects")
  File.rename("#{BUILD_DIRECTORY}/headers", "#{BUILD_DIRECTORY}/_headers")
  sh "npm run pagefind"
end
