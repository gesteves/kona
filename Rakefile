require 'rake/clean'
require 'dotenv/tasks'
require_relative 'lib/strava'
require_relative 'lib/contentful'
require 'yaml'

CLOBBER.include %w{
  data/*.json
}

namespace :import do
  directory 'data'

  task :set_up_directories => %w{
    data
  }

  desc 'Imports content from Contentful'
  task :contentful => [:dotenv, :set_up_directories] do
    puts 'Importing site content from Contentful'
    Contentful.content
  end

  desc 'Imports content from Strava'
  task :strava => [:dotenv, :set_up_directories] do
    puts 'Importing Strava data'
    Strava.new.save_data
  end

end

task :import => %w{
  clobber
  import:contentful
  import:strava
}

desc 'Import content and build the site'
task :build => [:dotenv, :import] do
  puts 'Building the site'
  sh 'middleman build'
  File.rename("build/redirects", "build/_redirects")
end

namespace :build do
  desc 'Import content and build the site'
  task :verbose => [:dotenv, :import] do
    puts 'Building the site'
    sh 'middleman build --verbose'
    File.rename("build/redirects", "build/_redirects")
  end
end
