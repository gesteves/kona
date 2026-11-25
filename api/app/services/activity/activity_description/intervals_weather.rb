module ActivityDescription
  # The weather that Intervals.icu holds for an activity, in metric units. Weather uses it when
  # WeatherKit has no data for the track. It has no humidity and no weather for each point.
  class IntervalsWeather
    # @param activity [Hash] The Intervals.icu activity.
    # @param intervals [#activity_weather_summary, nil] The source of the full weather summary.
    #   With nil, this reads the fields of the activity only.
    def initialize(activity, intervals: nil)
      @activity = activity
      @intervals = intervals
    end

    # It reads the activity only, thus it makes no request.
    # @return [Boolean] True when Intervals.icu has the weather of the activity.
    def available?
      [ @activity[:has_weather], @activity[:min_weather_temp], @activity[:max_weather_temp] ].all?
    end

    # Snow and rain first, then the cloud cover. The precipitation values are the highest rates of
    # the activity, thus any amount names the condition. ⚠️ Intervals.icu keeps the showers apart
    # from the rain, thus an activity with showers alone has a `max_rain` of zero.
    # @return [String] A condition code of config/conditions.yml.
    def condition_code
      rain = (data[:max_rain].to_f + data[:max_showers].to_f).positive?
      snow = data[:max_snow].to_f.positive?
      return "MixedRainAndSnow" if rain && snow
      return "Snow" if snow
      return "Rain" if rain

      ConditionCodes.for_cloud_cover(data[:average_clouds].to_f)
    end

    # @return [Array(Numeric, Numeric)] The lowest and the highest temperature, in °C. Each one can
    #   be nil.
    def temperatures = data.values_at(:min_weather_temp, :max_weather_temp)

    # @return [Array(Numeric, Numeric)] The lowest and the highest feels-like, in °C. Each one can
    #   be nil.
    def feels_like = data.values_at(:min_feels_like, :max_feels_like)

    # With no range in the data, the range is the average alone.
    # @return [Array(Float, Float), nil] The lowest and the highest wind speed, in km/h. Nil with
    #   no wind speed at all.
    def wind_speeds_kph
      average = data[:average_wind_speed]
      lowest = data[:min_wind_speed] || average
      highest = data[:max_wind_speed] || average
      return if lowest.nil? || highest.nil?

      [ kph(lowest), kph(highest) ]
    end

    # @return [Float] The highest gust, or the average gust with no highest one, in km/h. Zero with
    #   neither.
    def gust_kph = kph(data[:max_wind_gust] || data[:average_wind_gust])

    # @return [Float] The mean wind speed, in km/h. Zero with none.
    def mean_wind_kph = kph(data[:average_wind_speed])

    # @return [Numeric, nil] The direction that the prevailing wind comes from, in degrees.
    def wind_degrees = data[:prevailing_wind_deg]

    # ⚠️ This share comes from a sector of Intervals.icu, and not from the head component of
    # Weather#headwind_percent. Thus the two numbers do not have the same meaning.
    # @return [Integer, nil] The share of the time with a headwind, in percent.
    def headwind_percent = data[:headwind_percent]&.to_f&.round

    private

    # The fields of the activity, with the fields of the full weather summary over them. The
    # activity has an average wind and an average gust only, and no showers.
    def data
      @data ||= begin
        extra = @activity[:id] && @intervals&.activity_weather_summary(@activity[:id])
        @activity.merge(extra.to_h.compact)
      end
    end

    # @param mps [Numeric, nil] A speed in m/s, which is the unit of Intervals.icu.
    def kph(mps) = mps.to_f * 3.6
  end
end
