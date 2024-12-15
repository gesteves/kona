require 'dotenv/tasks'
require 'rake/clean'
require 'redis'

# Require all Ruby files in the lib/data directory
Dir["lib/data/*.rb"].each { |file| require_relative file }

DATA_DIRECTORY = 'data'
BUILD_DIRECTORY = 'build'

# Remove all existing data files from previous imports.
CLOBBER.include %w{ data/*.json }

desc 'Imports all content for the site'
task :import => [:dotenv, :clobber] do
  setup_data_directory
  initialize_redis
  initialize_location
  measure_and_output(:import_contentful, "Importing site content")
  measure_and_output(:import_font_awesome, "Importing icons")
  measure_and_output(:import_intervals, "Importing activity stats")
  measure_and_output(:import_location, "Importing location data")
  measure_and_output(:import_weather, "Importing weather data")
  measure_and_output(:import_aqi, "Importing air quality data")
  measure_and_output(:import_pollen, "Importing pollen data")
  measure_and_output(:import_trainer_road, "Importing today’s workouts")
  measure_and_output(:import_dark_visitors, "Importing robots.txt directives")
  measure_and_output(:import_plausible, "Importing Plausible analytics data")
end

desc 'Run the test suite'
task :test do
  puts 'Running tests...'
  sh 'bundle exec rspec'
end

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

namespace :redis do
  desc 'Empties the Redis instance after confirmation'
  task :clear do
    puts 'WARNING: You are about to completely empty the Redis instance. This action is irreversible!'
    print 'Type "execute" to proceed: '
    confirmation = STDIN.gets.strip
    if confirmation.downcase == 'execute'
      $redis.flushdb
      puts 'Redis instance has been emptied.'
    else
      puts 'Redis empty action cancelled.'
    end
  end
end

# Methods for tasks

def setup_data_directory
  FileUtils.mkdir_p(DATA_DIRECTORY)
end

def initialize_redis
  $redis ||= Redis.new(
    host: ENV['REDIS_HOST'] || 'localhost',
    port: ENV['REDIS_PORT'] || 6379,
    username: ENV['REDIS_USERNAME'],
    password: ENV['REDIS_PASSWORD']
  )
end

def initialize_location
  @location ||= Location.new
end

def import_contentful
  safely_perform { Contentful.new.save_data }
end

def import_font_awesome
  safely_perform { FontAwesome.new.save_data }
end

def import_intervals
  safely_perform { Intervals.new.save_data }
end

def import_location
  safely_perform {
    @google_maps ||= GoogleMaps.new(@location.latitude, @location.longitude)
    @google_maps.save_data
  }
end

def import_weather
  safely_perform {
    @google_maps ||= GoogleMaps.new(@location.latitude, @location.longitude)
    WeatherKit.new(@google_maps.latitude, @google_maps.longitude, @google_maps.time_zone_id, @google_maps.country_code).save_data
  }
end

def import_aqi
  safely_perform {
    @google_maps ||= GoogleMaps.new(@location.latitude, @location.longitude)
    purple_air = PurpleAir.new(@google_maps.latitude, @google_maps.longitude)
    if purple_air.aqi.present?
      purple_air.save_data
    else
      GoogleAirQuality.new(@google_maps.latitude, @google_maps.longitude, @google_maps.country_code).save_data
    end
  }
end

def import_pollen
  safely_perform {
    @google_maps ||= GoogleMaps.new(@location.latitude, @location.longitude)
    GooglePollen.new(@google_maps.latitude, @google_maps.longitude).save_data 
  }
end

def import_trainer_road
  safely_perform {
    @google_maps ||= GoogleMaps.new(@location.latitude, @location.longitude)
    TrainerRoad.new(@google_maps.time_zone_id).save_data 
  }
end

def import_dark_visitors
  safely_perform {
    DarkVisitors.new.save_data 
  }
end

def import_plausible
  safely_perform {
    Plausible.new.save_data
  }
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
