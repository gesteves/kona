DATA_DIRECTORY = 'data'

# Remove all existing data files from previous imports.
CLOBBER.include %w{ data/*.json }

namespace :import do
  desc 'Imports FontAwesome icons'
  task :icons => [:dotenv] do
    setup_data_directory
    initialize_redis
    measure_and_output(:import_font_awesome, "Importing icons")
  end

  desc 'Imports Contentful content'
  task :content => [:dotenv] do
    setup_data_directory
    initialize_redis
    measure_and_output(:import_contentful, "Importing site content")
  end

  desc 'Imports weather data'
  task :weather => [:dotenv] do
    setup_data_directory
    initialize_redis
    initialize_location
    measure_and_output(:import_location, "Importing location data")
    measure_and_output(:import_weather, "Importing weather data")
    measure_and_output(:import_aqi, "Importing air quality data")
    measure_and_output(:import_pollen, "Importing pollen data")
  end
end

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
  measure_and_output(:import_trainer_road, "Importing today's workouts")
  measure_and_output(:import_dark_visitors, "Importing robots.txt directives")
end

def setup_data_directory
  FileUtils.mkdir_p(DATA_DIRECTORY)
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

def safely_perform
  yield
rescue => e
  puts "Error occurred: #{e.message}"
end

def measure_and_output(method, description)
  puts description
  start_time = Time.now
  send(method)
  duration = Time.now - start_time
  puts "  Completed in #{duration.round(2)} seconds"
end
