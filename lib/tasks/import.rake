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
  measure_and_output(:import_trainer_road, "Importing today’s workouts")
  measure_and_output(:import_dark_visitors, "Importing robots.txt directives")
end
