require 'dotenv/tasks'
require 'rake/clean'
require 'yaml'

Dir["lib/data/*.rb"].each do |file|
  require_relative file
end

CLOBBER.include %w{
  data/*.json
}

namespace :import do
  directory 'data'

  task :set_up_directories => %w{
    data
  }

  contentful = Contentful.new

  desc 'Imports content from Contentful'
  task :contentful => [:dotenv, :set_up_directories] do
    puts 'Importing site content from Contentful'
    contentful.save_data
  end

  desc 'Imports content from Strava'
  task :strava => [:dotenv, :set_up_directories] do
    puts 'Importing activity stats from Strava'
    Strava.new.save_data
  end

  desc 'Imports location & weather data'
  task :weather => [:dotenv, :set_up_directories] do
    puts 'Getting most recent check-in from Swarm'
    swarm = Swarm.new
    checkin = swarm.recent_checkin_location

    if checkin[:latitude].nil? || checkin[:longitude].nil?
      puts "No recent Swarm check-ins found, using Contentful location as a fallback"
      latitude = contentful.location[:lat]
      longitude = contentful.location[:lon]
    else
      latitude = checkin[:latitude]
      longitude = checkin[:longitude]
    end

    if latitude.nil? || longitude.nil?
      puts "No location available, skipping weather data"
      next
    end

    puts 'Importing geocoded location data from Google Maps'
    maps = GoogleMaps.new(latitude, longitude)
    maps.save_data
    country = maps.country_code
    time_zone = maps.time_zone

    puts 'Importing weather data from WeatherKit'
    weather = WeatherKit.new(latitude, longitude, time_zone, country)
    weather.save_data

    puts 'Importing air quality data from PurpleAir'
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
