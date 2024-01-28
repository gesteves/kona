require 'httparty'
require 'redis'
require 'active_support/all'

# The PurpleAir class interfaces with the PurpleAir API to fetch air quality data.
class PurpleAir
  PURPLE_AIR_API_URL = 'https://api.purpleair.com/v1/sensors'

  # Initializes the PurpleAir class with geographical coordinates.
  # @param latitude [Float] The latitude for the air quality data.
  # @param longitude [Float] The longitude for the air quality data.
  # @return [PurpleAir] The instance of the PurpleAir class.
  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
  end

  # Fetches the Air Quality Index (AQI) based on the nearest sensor data.
  # @return [Hash, nil] The AQI and related data, or nil if fetching fails.
  def aqi
    sensor = nearest_sensor
    return if sensor.blank?
    raw_pm25 = sensor[:'pm2.5_atm']
    humidity = sensor[:humidity]
    pm25 = humidity.present? ? apply_epa_correction(raw_pm25, humidity.to_f) : raw_pm25
    sensor[:aqi] = format_aqi(pm25)
    sensor
  end

  # Saves the AQI data to a JSON file.
  def save_data
    File.open('data/purple_air.json', 'w') { |f| f << aqi.to_json }
  end

  private

  # Finds sensors within a defined proximity.
  # @see https://api.purpleair.com/#api-sensors-get-sensors-data
  # @return [Hash, nil] The sensor data, or nil if fetching fails.
  def find_sensors
    cache_key = "purple_air:sensors:#{api_query_params.values.map(&:to_s).join(':')}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    response = HTTParty.get(PURPLE_AIR_API_URL, query: api_query_params, headers: { 'X-API-Key' => ENV['PURPLEAIR_API_KEY'] })
    return unless response.success?

    @redis.setex(cache_key, 1.hour, response.body)
    JSON.parse(response.body)
  end

  # Constructs query parameters for the API request.
  # @return [Hash] The API query parameters.
  def api_query_params
    {
      location_type: 0,
      fields: 'pm2.5_atm,latitude,longitude,humidity',
      nwlat: @latitude + 0.1,
      selat: @latitude - 0.1,
      nwlng: @longitude - 0.1,
      selng: @longitude + 0.1
    }
  end

  # Identifies the nearest air quality sensor based on the current location.
  # @return [Hash, nil] The nearest sensor data, or nil if none are close enough.
  def nearest_sensor
    sensors = find_sensors
    return if sensors['data'].blank?

    fields = sensors['fields'].map(&:to_sym)
    lat_index = fields.index(:latitude)
    lon_index = fields.index(:longitude)

    nearest_sensor_data = sensors['data'].reject { |sensor| sensor[lat_index].blank? || sensor[lon_index].blank? }.min_by do |sensor|
      lat, lon = sensor[lat_index], sensor[lon_index]
      Math.sqrt((lat - @latitude)**2 + (lon - @longitude)**2)
    end

    return if nearest_sensor_data.blank?

    # Combine the fields with the corresponding data for the nearest sensor
    fields.zip(nearest_sensor_data).to_h
  end

  # Applies EPA correction to raw PM2.5 data based on humidity.
  # @see https://community.purpleair.com/t/is-there-a-field-that-returns-data-with-us-epa-pm2-5-conversion-formula-applied/4593
  # @see https://cfpub.epa.gov/si/si_public_record_report.cfm?dirEntryId=353088&Lab=CEMM
  # @param pm25 [Float] The raw PM2.5 measurement.
  # @param humidity [Float] The humidity measurement.
  # @return [Float] The corrected PM2.5 value.
  def apply_epa_correction(pm25, humidity)
    case pm25
    when 0...30
      0.524 * pm25 - 0.0862 * humidity + 5.75
    when 30...50
      ((0.786 * (pm25 / 20 - 3 / 2) + 0.524 * (1 - (pm25 / 20 - 3 / 2))) * pm25) - 0.0862 * humidity + 5.75
    when 50...210
      0.786 * pm25 - 0.0862 * humidity + 5.75
    when 210...260
      ((0.69 * (pm25 / 50 - 21 / 5) + 0.786 * (1 - (pm25 / 50 - 21 / 5))) * pm25) -
        0.0862 * humidity * (1 - (pm25 / 50 - 21 / 5)) +
        2.966 * (pm25 / 50 - 21 / 5) +
        5.75 * (1 - (pm25 / 50 - 21 / 5)) +
        8.84 * (10**(-4)) * pm25**2 * (pm25 / 50 - 21 / 5)
    else
      2.966 + 0.69 * pm25 + 8.841 * (10**(-4)) * pm25**2
    end
  end

  # Formats the PM2.5 value into an Air Quality Index (AQI).
  # @param pm25 [Float] The PM2.5 value to be converted.
  # @return [Hash] The formatted AQI value and label.
  def format_aqi(pm25)
    return {} if pm25.blank?

    aqi, label = case pm25
                 when 0..12.0
                   [calculate_aqi(pm25, 50, 0, 12.0, 0), 'Good']
                 when 12.1..35.4
                   [calculate_aqi(pm25, 100, 51, 35.4, 12.1), 'Moderate']
                 when 35.5..55.4
                   [calculate_aqi(pm25, 150, 101, 55.4, 35.5), 'Unhealthy for Sensitive Groups']
                 when 55.5..150.4
                   [calculate_aqi(pm25, 200, 151, 150.4, 55.5), 'Unhealthy']
                 when 150.5..250.4
                   [calculate_aqi(pm25, 300, 201, 250.4, 150.5), 'Very Unhealthy']
                 when 250.5..350.4
                   [calculate_aqi(pm25, 400, 301, 350.4, 250.5), 'Hazardous']
                 when 350.5..500.4
                   [calculate_aqi(pm25, 500, 401, 500.4, 350.5), 'Hazardous']
                 else
                   [nil, nil]
                 end

    { value: aqi, label: label }.compact
  end

  # Calculates the AQI based on PM2.5 value and breakpoints.
  # @param pm25 [Float] The PM2.5 value.
  # @param aqi_high [Integer] The high end of the AQI range.
  # @param aqi_low [Integer] The low end of the AQI range.
  # @param pm25_high [Float] The high PM2.5 breakpoint.
  # @param pm25_low [Float] The low PM2.5 breakpoint.
  # @return [Float] The calculated AQI value.
  def calculate_aqi(pm25, aqi_high, aqi_low, pm25_high, pm25_low)
    aqi_range = aqi_high - aqi_low
    pm25_range = pm25_high - pm25_low
    difference_from_low_breakpoint = pm25 - pm25_low
    (aqi_range / pm25_range) * difference_from_low_breakpoint + aqi_low
  end

end
