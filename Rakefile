require 'rake/clean'
require 'dotenv/tasks'
require_relative 'lib/strava'
require_relative 'lib/contentful'
require_relative 'lib/weather_kit'
require_relative 'lib/google_maps'
require_relative 'lib/purple_air'
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

  desc 'Imports weather from WeatherKit'
  task :weather => [:dotenv, :set_up_directories] do
    puts 'Importing weather'
    latitude, longitude = Contentful.site_location
    maps = GoogleMaps.new(latitude, longitude)
    maps.save_data
    country = maps.country_code
    time_zone = maps.time_zone
    weather = WeatherKit.new(latitude, longitude, time_zone, country)
    weather.save_data
    PurpleAir.new(latitude, longitude).save_data
  end

end

task :import => %w{
  clobber
  import:contentful
  import:strava
  import:weather
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
