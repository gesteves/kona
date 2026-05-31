# Fetches air quality from the nearest PurpleAir sensor (US-centric), applying the EPA
# humidity correction and converting PM2.5 to an AQI. `aqi` returns
# { aqi:, category:, description: } or nil when no usable sensor is nearby.
class PurpleAir < ApplicationService
  attr_reader :aqi
  PURPLE_AIR_API_URL = "https://api.purpleair.com/v1/sensors"

  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
    @aqi = get_aqi
  end

  private

  def get_aqi
    return if @latitude.blank? || @longitude.blank? || ENV["PURPLEAIR_API_KEY"].blank?

    sensor = nearest_sensor_within_distance
    return if sensor.blank?

    corrected_pm25 = apply_epa_correction(sensor["pm2.5_atm"], sensor["humidity"])
    return unless corrected_pm25&.positive?
    data = format_aqi(corrected_pm25)
    return unless data.dig(:aqi)&.positive?
    data
  end

  def nearest_sensor_within_distance(distance_km = 1)
    sensors = find_sensors_within_distance(distance_km)
    return if sensors.blank? || sensors["data"].blank?

    fields = sensors["fields"]
    lat_index = fields.index("latitude")
    lon_index = fields.index("longitude")
    confidence_index = fields.index("confidence")

    valid_sensors = sensors["data"].reject { |sensor| sensor[confidence_index] < 50 }
    return if valid_sensors.blank?

    nearest_sensor_data = valid_sensors.min_by { |sensor| haversine_distance(@latitude, @longitude, sensor[lat_index], sensor[lon_index]) }
    fields.zip(nearest_sensor_data).to_h
  end

  # @see https://api.purpleair.com/#api-sensors-get-sensors-data
  def find_sensors_within_distance(distance_km)
    bounding_box = calculate_bounding_box(@latitude, @longitude, distance_km)
    query = bounding_box.merge(location_type: 0, max_age: 1.hour, fields: "pm2.5_atm,latitude,longitude,humidity,confidence")

    cache_key = "purple_air:sensors:#{query.values.map(&:to_s).join(':')}"
    cached_json(cache_key, expires_in: 5.minutes, symbolize: false) do
      get_json(PURPLE_AIR_API_URL, symbolize: false, query: query, headers: { "X-API-Key" => ENV["PURPLEAIR_API_KEY"] })
    end
  end

  # Applies the EPA humidity correction to raw PM2.5.
  # @see https://cfpub.epa.gov/si/si_public_record_report.cfm?dirEntryId=353088&Lab=CEMM
  def apply_epa_correction(pm25, humidity)
    return if pm25.blank?
    return pm25 if humidity.blank?

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

  # Converts PM2.5 to an AQI value and category.
  # @see https://www.epa.gov/system/files/documents/2024-02/pm-naaqs-air-quality-index-fact-sheet.pdf
  def format_aqi(pm25)
    return if pm25.blank?
    pm25 = pm25.round(1)
    aqi, category = case pm25
                    when 0..9.0
                      [calculate_aqi(pm25, 0, 9.0, 0, 50), "Good"]
                    when 9.1..35.4
                      [calculate_aqi(pm25, 9.1, 35.4, 51, 100), "Moderate"]
                    when 35.5..55.4
                      [calculate_aqi(pm25, 35.5, 55.4, 101, 150), "Unhealthy for sensitive groups"]
                    when 55.5..125.4
                      [calculate_aqi(pm25, 55.5, 125.4, 151, 200), "Unhealthy"]
                    when 125.5..225.4
                      [calculate_aqi(pm25, 125.5, 225.4, 201, 300), "Very unhealthy"]
                    else
                      [calculate_aqi(pm25, 225.5, 500.0, 301, 500), "Hazardous"]
                    end

    description = category == "Unhealthy for sensitive groups" ? "Unhealthy air quality for sensitive groups" : "#{category} air quality"
    { aqi: aqi, category: category, description: description }.compact
  end

  def calculate_aqi(pm25, pm25_low, pm25_high, aqi_low, aqi_high)
    pm25 = pm25.round(1)
    if pm25 > 500
      (((aqi_high - aqi_low) / (pm25_high - pm25_low)) * (pm25 - pm25_high) + aqi_high).round
    else
      ((((aqi_high - aqi_low) / (pm25_high - pm25_low)) * (pm25 - pm25_low)) + aqi_low).round
    end
  end

  # @see https://en.wikipedia.org/wiki/Haversine_formula
  def haversine_distance(lat1, lon1, lat2, lon2)
    earth_radius_km = 6371.0
    lat1 = lat1 * Math::PI / 180
    lat2 = lat2 * Math::PI / 180
    lon1 = lon1 * Math::PI / 180
    lon2 = lon2 * Math::PI / 180

    delta_lat = lat2 - lat1
    delta_lon = lon2 - lon1

    a = Math.sin(delta_lat / 2)**2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(delta_lon / 2)**2
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
    earth_radius_km * c
  end

  def calculate_bounding_box(latitude, longitude, distance_km)
    latitude_delta = distance_km / 111.0
    longitude_delta = distance_km / (111.0 * Math.cos(latitude * Math::PI / 180))

    nwlat = (latitude + latitude_delta).clamp(-90, 90)
    selat = (latitude - latitude_delta).clamp(-90, 90)
    nwlng = longitude - longitude_delta
    selng = longitude + longitude_delta
    nwlng += 360 if nwlng < -180
    selng -= 360 if selng > 180

    { nwlat: nwlat, selat: selat, nwlng: nwlng, selng: selng }
  end
end
