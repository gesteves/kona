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
