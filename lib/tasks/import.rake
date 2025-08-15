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

  desc 'Imports Whoop data'
  task :whoop => [:dotenv] do
    setup_data_directory
    initialize_redis
    initialize_location
    measure_and_output(:import_whoop, "Importing Whoop data")
  end

end

desc 'Imports all content for the site'
task :import => [:dotenv, :clobber] do
  puts "=" * 60
  puts "🚀 Starting full site data import"
  puts "=" * 60
  
  overall_start_time = Time.now
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
  measure_and_output(:import_whoop, "Importing Whoop data")
  measure_and_output(:import_dark_visitors, "Importing robots.txt directives")
  
  total_duration = Time.now - overall_start_time
  puts "\n" + "=" * 60
  puts "🎉 Import completed! Total time: #{format_duration(total_duration)}"
  puts "=" * 60
end

def setup_data_directory
  FileUtils.mkdir_p(DATA_DIRECTORY)
end

def initialize_location
  @location ||= Location.new
end

def import_contentful
  Contentful.new.save_data
end

def import_font_awesome
  FontAwesome.new.save_data
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


def import_whoop
  safely_perform { 
    @google_maps ||= GoogleMaps.new(@location.latitude, @location.longitude)
    Whoop.new(@google_maps.time_zone_id).save_data 
  }
end

def import_dark_visitors
  DarkVisitors.new.save_data
end

def safely_perform
  yield
rescue => e
  puts "Error occurred: #{e.message}"
end

def measure_and_output(method, description)
  puts "\n🔄 #{description}..."
  start_time = Time.now
  
  begin
    send(method)
    duration = Time.now - start_time
    puts "✅ #{description} completed in #{format_duration(duration)}"
  rescue => e
    duration = Time.now - start_time
    puts "❎ #{description} failed after #{format_duration(duration)}"
    puts "   Error: #{e.message}"
    raise e
  end
end

def format_duration(seconds)
  if seconds < 1
    "#{(seconds * 1000).round}ms"
  elsif seconds < 60
    "#{seconds.round(2)}s"
  else
    minutes = (seconds / 60).floor
    remaining_seconds = (seconds % 60).round
    "#{minutes}m #{remaining_seconds}s"
  end
end
