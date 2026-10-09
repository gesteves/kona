module RaceWeather
  # Makes the cells and the Markdown table from the WeatherKit hours. This file uses the standard
  # library only, thus spec/race_weather_check.rb can run it with no bundle.
  #
  # Each hour is a Hash with the keys of WeatherKit, in metric units, and one more key: `localHour`,
  # the hour of the day at the location (0 to 23).
  module Format
    extend self

    HEADERS = %w[Date Weather Temperature Humidity Wind Rain AQI].freeze
    NO_DATA = 'No data'.freeze
    UNITS = %i[imperial metric].freeze

    MM_PER_INCH = 25.4
    MPH_PER_KPH = 0.621371
    # A total below this is a trace. 0.01" is the smallest amount that a rain gauge reports.
    TRACE_INCHES = 0.01
    TRACE_MM = 0.1

    # @param rows [Array<Array<String>>] The cells of each row, in the order of HEADERS.
    # @return [String] The Markdown table.
    def table(rows)
      lines = ["| #{HEADERS.join(' | ')} |", "|#{'---|' * HEADERS.size}"]
      rows.each { |cells| lines << "| #{cells.join(' | ')} |" }
      lines.join("\n")
    end

    # @param date [Date]
    # @param hours [Array<Hash>]
    # @param phrase [String, nil] The Weather cell.
    # @param aqi [Hash, nil] `{ aqi:, category: }`, or nil with no sensor.
    # @param units [Symbol] :imperial or :metric.
    # @return [Array<String>] The cells of one row.
    def row(date:, hours:, phrase:, aqi:, units:)
      [
        date.strftime('%b %-d, %Y'),
        phrase || NO_DATA,
        temperature(hours, units),
        humidity(hours),
        wind(hours, units),
        rain(hours, units),
        aqi ? "#{aqi[:aqi]}, #{aqi[:category]}" : NO_DATA
      ]
    end

    # @return [String] For example "58°F–83°F (feels like 57°F–84°F)".
    def temperature(hours, units)
      air = hours.filter_map { |hour| hour['temperature'] }
      feels = hours.filter_map { |hour| hour['temperatureApparent'] }
      return NO_DATA if air.empty?

      text = "#{degrees(air.min, units)}–#{degrees(air.max, units)}"
      text += " (feels like #{degrees(feels.min, units)}–#{degrees(feels.max, units)})" unless feels.empty?
      text
    end

    # @return [String] The mean relative humidity, for example "55%".
    def humidity(hours)
      values = hours.filter_map { |hour| hour['humidity'] }
      return NO_DATA if values.empty?

      "#{(values.sum / values.size * 100).round}%"
    end

    # @return [String] For example "Up to 9 mph, gusts 17 mph".
    def wind(hours, units)
      speeds = hours.filter_map { |hour| hour['windSpeed'] }
      gusts = hours.filter_map { |hour| hour['windGust'] }
      return NO_DATA if speeds.empty?

      text = "Up to #{speed(speeds.max, units)}"
      text += ", gusts #{speed(gusts.max, units)}" unless gusts.empty?
      text
    end

    # @return [String] "None", or the total and the wet hours, for example "Trace, 4 PM" or
    #   "0.01\", 3–9 PM".
    def rain(hours, units)
      wet = hours.select { |hour| hour['precipitationAmount'].to_f.positive? }
      return 'None' if wet.empty?

      total = wet.sum { |hour| hour['precipitationAmount'].to_f }
      "#{rain_amount(total, units)}, #{wet_spans(wet.map { |hour| hour['localHour'] })}"
    end

    # @param mm [Float] A total above zero.
    # @return [String] "Trace", or the amount with its unit.
    def rain_amount(mm, units)
      if units == :metric
        mm < TRACE_MM ? 'Trace' : "#{trim(mm.round(1))} mm"
      else
        inches = mm / MM_PER_INCH
        inches < TRACE_INCHES ? 'Trace' : "#{trim(inches.round(2))}\""
      end
    end

    # Labels each run of consecutive wet hours, from the start of its first hour to the end of its
    # last hour. A run of one hour gets the label of its start.
    # @param local_hours [Array<Integer>] The hours of the day (0 to 23).
    # @return [String] For example "3–9 PM", or "11 AM–2 PM, 10 PM–midnight".
    def wet_spans(local_hours)
      runs = local_hours.uniq.sort.slice_when { |a, b| b != a + 1 }
      runs.map { |run| span(run.first, run.last) }.join(', ')
    end

    # @param first [Integer] The first wet hour (0 to 23).
    # @param last [Integer] The last wet hour (0 to 23).
    # @return [String]
    def span(first, last)
      return clock(first) if first == last

      stop = last + 1
      if plain?(first) && plain?(stop) && meridiem(first) == meridiem(stop)
        "#{twelve(first)}–#{twelve(stop)} #{meridiem(stop)}"
      else
        "#{clock(first)}–#{clock(stop)}"
      end
    end

    # @param hour [Integer] 0 to 24.
    # @return [String] For example "4 PM", "noon", or "midnight".
    def clock(hour)
      case hour % 24
      when 0 then 'midnight'
      when 12 then 'noon'
      else "#{twelve(hour)} #{meridiem(hour)}"
      end
    end

    # @param code [String] A WeatherKit condition code, for example "MostlyClear".
    # @return [String] The words, for example "Mostly clear".
    def condition_words(code)
      code.to_s.gsub(/(?<=[a-z])([A-Z])/) { " #{Regexp.last_match(1).downcase}" }
    end

    # @param aqi [Integer]
    # @return [String] The EPA category. The words are the same as in the api.
    def aqi_category(aqi)
      case aqi
      when 0..50 then 'Good'
      when 51..100 then 'Moderate'
      when 101..150 then 'Unhealthy for sensitive groups'
      when 151..200 then 'Unhealthy'
      when 201..300 then 'Very unhealthy'
      else 'Hazardous'
      end
    end

    private

    def degrees(celsius, units)
      units == :metric ? "#{celsius.round}°C" : "#{(celsius * 9 / 5.0 + 32).round}°F"
    end

    def speed(kph, units)
      units == :metric ? "#{kph.round} km/h" : "#{(kph * MPH_PER_KPH).round} mph"
    end

    # @return [String] The number with no trailing zero, for example "0.3" and not "0.30".
    def trim(number)
      format('%g', number)
    end

    # @return [Boolean] True for an hour that is not noon and not midnight.
    def plain?(hour) = (hour % 12).nonzero?

    def twelve(hour) = (hour % 12).zero? ? 12 : hour % 12

    def meridiem(hour) = (hour % 24) < 12 ? 'AM' : 'PM'
  end
end
