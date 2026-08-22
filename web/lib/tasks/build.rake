BUILD_DIRECTORY = "build"

# `rake build` does NOT run the test suite. Use `rake test` for that. The two are separate, thus a
# build from a Contentful publish is not slower because of a test run that it does not need.
desc "Import content and build the site"
task build: [ :dotenv, :import ] do
  build_site
end

namespace :build do
  desc "Import content and build the site with verbose output"
  task verbose: [ :dotenv, :import ] do
    build_site(verbose: true)
  end

  # This does not run :import, thus it builds the data that `rake import` last wrote to data/. Use it
  # to make build/ again during a `wrangler dev` session. `rake build:verbose` is still the check
  # before a commit.
  desc "Build the site from the existing data/ without re-importing"
  task fast: [ :dotenv ] do
    build_site
  end
end

# Builds the site. The external pipeline of Middleman makes the JavaScript and CSS bundle: it runs
# `npm run build` itself and it waits for the end of that command.
def build_site(verbose: false)
  middleman_command = verbose ? "middleman build --verbose" : "middleman build"
  sh middleman_command
  # A file in source/ with an underscore at the start of its name is a partial. Thus these files have
  # no underscore, and this code renames them.
  File.rename("#{BUILD_DIRECTORY}/redirects", "#{BUILD_DIRECTORY}/_redirects")
  File.rename("#{BUILD_DIRECTORY}/headers", "#{BUILD_DIRECTORY}/_headers")
  sh "npm run pagefind"
end
