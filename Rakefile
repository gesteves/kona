require 'dotenv/tasks'
require 'rake/clean'
require 'yaml'

# Require all Ruby files in the lib/data directory
Dir["lib/data/*.rb"].each { |file| require_relative file }

DATA_DIRECTORY = 'data'
BUILD_DIRECTORY = 'build'

# Remove all existing data files from previous imports.
CLOBBER.include %w{ data/*.json }

desc 'Imports all content for the site'
task :import => [:dotenv, :clobber] do
  setup_data_directory
  import_contentful
  import_strava
  import_location_and_weather_data
  import_trainer_road
  puts 'All import tasks completed'
end

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

# Methods for tasks

# Sets up the data directory where the JSON files will get saved.
def setup_data_directory
  puts 'Setting up data directory'
  FileUtils.mkdir_p(DATA_DIRECTORY)
end

# Imports content from Contentful
def import_contentful
  puts 'Importing site content from Contentful'
  safely_perform { Contentful.new.save_data }
end

# Imports activity stats from Strava
def import_strava
  puts 'Importing activity stats from Strava'
  safely_perform { Strava.new.save_data }
end

# Imports location and weather data
def import_location_and_weather_data
  puts 'Getting most recent check-in from Swarm'
  swarm = Swarm.new
  contentful = Contentful.new
  latitude, longitude = fetch_location(contentful, swarm)

  # If we don't have a location, then we can't get weather or AQI data.
  return if latitude.nil? || longitude.nil?

  puts 'Geocoding location in Google Maps'
  safely_perform {
    maps = GoogleMaps.new(latitude, longitude)
    maps.save_data
    import_weather_and_air_quality_data(latitude, longitude, maps)
  }
end

# Fetches my current location, either from my latest Swarm checkin,
# or falling back to what's set in Contentful.
# @param contentful [Object] Contentful object for location fallback
# @param swarm [Object] Swarm object to get recent check-in
# @return [Array<Float, Float>] Latitude and longitude
def fetch_location(contentful, swarm)
  checkin = swarm.recent_checkin_location
  if checkin[:latitude].nil? || checkin[:longitude].nil?
    puts "No recent Swarm check-ins found, using Contentful location as a fallback"
    return [contentful.location[:lat], contentful.location[:lon]]
  end
  [checkin[:latitude], checkin[:longitude]]
end

# Imports weather and air quality data
def import_weather_and_air_quality_data(latitude, longitude, maps)
  country = maps.country_code
  time_zone = maps.time_zone['timeZoneId']

  puts 'Importing weather data from WeatherKit'
  weather = WeatherKit.new(latitude, longitude, time_zone, country)
  weather.save_data

  puts 'Importing air quality data from PurpleAir'
  PurpleAir.new(latitude, longitude).save_data
end

# Imports today's workouts from TrainerRoad
def import_trainer_road
  puts 'Importing today’s workouts from TrainerRoad'
  time_zone = ENV['DEFAULT_TIMEZONE'] || 'UTC'
  safely_perform { TrainerRoad.new(time_zone).save_data }
end

# Builds the entire site
# @param verbose [Boolean] Whether to build the site with verbose output
def build_site(verbose: false)
  puts 'Building the site'
  sh 'npm run build'
  middleman_command = verbose ? 'middleman build --verbose' : 'middleman build'
  sh middleman_command
  File.rename("#{BUILD_DIRECTORY}/redirects", "#{BUILD_DIRECTORY}/_redirects")
end

# Safely performs a block of code with error handling
# @yield The block of code to execute
def safely_perform
  yield
rescue => e
  puts "Error occurred: #{e.message}"
end
