require 'dotenv/tasks'
require 'rake/clean'
require 'yaml'

Dir["lib/data/*.rb"].each do |file|
  require_relative file
end

CLOBBER.include %w{
  data/*.json
}

desc 'Imports all content for the site'
task :import => [:dotenv, :clobber] do
  puts 'Setting up data directory'
  directory = 'data'
  mkdir_p(directory) unless File.directory?(directory)
  
  contentful = Contentful.new

  puts 'Importing site content from Contentful'
  contentful.save_data

  puts 'Importing activity stats from Strava'
  Strava.new.save_data

  # Imports location & weather data
  puts 'Getting most recent check-in from Swarm'
  swarm = Swarm.new
  checkin = swarm.recent_checkin_location
  time_zone = nil

  if checkin[:latitude].nil? || checkin[:longitude].nil?
    puts "No recent Swarm check-ins found, using Contentful location as a fallback"
    latitude = contentful.location[:lat]
    longitude = contentful.location[:lon]
  else
    latitude = checkin[:latitude]
    longitude = checkin[:longitude]
  end

  if latitude.nil? || longitude.nil?
    puts "No location available, skipping weather and AQI data"
  else
    puts 'Reverse geocoding location in Google Maps'
    maps = GoogleMaps.new(latitude, longitude)
    maps.save_data
    country = maps.country_code
    time_zone = maps.time_zone

    puts 'Importing weather data from WeatherKit'
    weather = WeatherKit.new(latitude, longitude, time_zone[:timeZoneId], country)
    weather.save_data

    puts 'Importing air quality data from PurpleAir'
    PurpleAir.new(latitude, longitude).save_data
  end

  puts 'Importing today’s workouts from TrainerRoad'
  TrainerRoad.new(time_zone.dig(:timeZoneId)).save_data

  puts 'All import tasks completed'
end

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
