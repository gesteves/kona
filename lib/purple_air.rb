require 'httparty'
require 'redis'
require 'active_support/all'

class PurpleAir
  PURPLE_AIR_API_URL = 'https://api.purpleair.com/v1/sensors'

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

  def save_data
    sensor = nearest_sensor
    return if sensor.blank?
    sensor[:aqi] = formatted_aqi(nearest_sensor[:'pm2.5_atm'])
    sensor
    File.open('data/purple_air.json', 'w') { |f| f << sensor.to_json }
  end

  private

  def find_sensors
    cache_key = "purple_air:sensors:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    response = HTTParty.get(PURPLE_AIR_API_URL, query: api_query_params, headers: { 'X-API-Key' => ENV['PURPLEAIR_API_KEY'] })
    return unless response.success?

    @redis.setex(cache_key, 1.hour, response.body)
    JSON.parse(response.body)
  end

  def api_query_params
    {
      location_type: 0,
      fields: 'name,pm2.5_atm,latitude,longitude',
      nwlat: @latitude + 0.1,
      selat: @latitude - 0.1,
      nwlng: @longitude - 0.1,
      selng: @longitude + 0.1
    }
  end

  def nearest_sensor
    sensors = find_sensors
    return if sensors['data'].blank?

    fields = sensors['fields'].map(&:to_sym)
    lat_index = fields.index(:latitude)
    lon_index = fields.index(:longitude)

    nearest_sensor_data = sensors['data'].min_by do |sensor|
      lat, lon = sensor[lat_index], sensor[lon_index]
      Math.sqrt((lat - @latitude)**2 + (lon - @longitude)**2)
    end

    # Combine the fields with the corresponding data for the nearest sensor
    fields.zip(nearest_sensor_data).to_h
  end

  def formatted_aqi(pm25)
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

  def calculate_aqi(cp, ih, il, bph, bpl)
    a = (ih - il)
    b = (bph - bpl)
    c = (cp - bpl)
    (a / b) * c + il
  end
end
