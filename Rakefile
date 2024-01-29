require 'dotenv/tasks'
require 'rake/clean'
require 'yaml'

# Require all Ruby files in the lib/data directory
Dir["lib/data/*.rb"].each { |file| require_relative file }

DATA_DIRECTORY = 'data'
BUILD_DIRECTORY = 'build'

# Remove all existing data files from previous imports.
CLOBBER.include %w{ data/*.json }

@contentful = nil
@geocoded = nil

desc 'Imports all content for the site'
task :import => [:dotenv, :clobber] do
  setup_data_directory
  measure_and_output(:import_contentful, "Importing site content from Contentful")
  measure_and_output(:import_strava, "Importing activity stats from Strava")
  measure_and_output(:import_location, "Importing location data from Swarm")
  measure_and_output(:import_weather, "Importing weather data from WeatherKit")
  measure_and_output(:import_aqi, "Importing air quality data from PurpleAir")
  measure_and_output(:import_trainer_road, "Importing today’s workouts from TrainerRoad")
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

def setup_data_directory
  FileUtils.mkdir_p(DATA_DIRECTORY)
end

def import_contentful
  @contentful ||= Contentful.new
  safely_perform { @contentful.save_data }
end

def import_strava
  safely_perform { Strava.new.save_data }
end

def import_location
  swarm = Swarm.new
  @contentful ||= Contentful.new
  latitude, longitude = fetch_location(@contentful, swarm)

  return if latitude.nil? || longitude.nil?

  puts '  Geocoding location in Google Maps'
  safely_perform {
    @geocoded = GoogleMaps.new(latitude, longitude)
    @geocoded.save_data
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
    puts '  No recent Swarm check-ins; using default location from Contentful'
    return [contentful.location[:lat], contentful.location[:lon]]
  end
  [checkin[:latitude], checkin[:longitude]]
end

# Imports weather data
def import_weather
  return if @geocoded.nil?

  WeatherKit.new(@geocoded.latitude, @geocoded.longitude, @geocoded.time_zone['timeZoneId'], @geocoded.country_code).save_data
end

# Imports air quality data
def import_aqi
  return if @geocoded.nil?

  PurpleAir.new(@geocoded.latitude, @geocoded.longitude).save_data
end

# Imports today's workouts from TrainerRoad
def import_trainer_road
  time_zone = @geocoded.nil? ? "UTC" : @geocoded.time_zone['timeZoneId']
  safely_perform { TrainerRoad.new(time_zone).save_data }
end

# Builds the entire site
# @param verbose [Boolean] Whether to build the site with verbose output
def build_site(verbose: false)
  # Use NETLIFY_BUILD_DEBUG env var to override the verbose flag if set to "true"
  verbose = true if ENV['NETLIFY_BUILD_DEBUG'] == 'true'

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

# Measures the execution time of a specified method and outputs the result.
# @param method [Symbol] The method to be executed and measured.
# @param description [String] A description of the task being measured.
def measure_and_output(method, description)
  puts description
  start_time = Time.now
  send(method)
  duration = Time.now - start_time
  puts "  Completed in #{duration.round(2)} seconds"
end
