module TaskHelpers
  DATA_DIRECTORY = 'data'
  BUILD_DIRECTORY = 'build'

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

  def build_site(verbose: false)
    verbose = true if ENV['NETLIFY_BUILD_DEBUG'] == 'true'

    sh 'npm run build'
    middleman_command = verbose ? 'middleman build --verbose' : 'middleman build'
    sh middleman_command
    File.rename("#{BUILD_DIRECTORY}/redirects", "#{BUILD_DIRECTORY}/_redirects")
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
end
