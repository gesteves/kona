require 'date'

module RaceWeather
  # Parses the race date and finds the past dates to compare. This file uses the standard library
  # only, thus spec/race_weather_check.rb can run it with no bundle.
  module Dates
    extend self

    # ⚠️ Date.parse reads "08/15/2027" day first and fails. Thus this pattern reads a slash date in
    # the US order before Date.parse sees it.
    US_SLASH = %r{\A(\d{1,2})/(\d{1,2})/(\d{2}|\d{4})\z}

    # @param text [String] A date in almost any format, for example "August 15, 2027",
    #   "2027-08-15", or "8/15/2027".
    # @return [Date]
    # @raise [ArgumentError] When the text is not a date.
    def parse(text)
      text = text.to_s.strip
      raise ArgumentError, 'no race date' if text.empty?

      if (match = US_SLASH.match(text))
        year = match[3].to_i
        year += 2000 if match[3].length == 2
        return Date.new(year, match[1].to_i, match[2].to_i)
      end

      begin
        Date.iso8601(text)
      rescue Date::Error
        Date.parse(text)
      end
    rescue Date::Error
      raise ArgumentError, "not a date: #{text.inspect}"
    end

    # The date in a year that has the weekday of the race and is closest to its month and day.
    # Feb 29 becomes Feb 28 in a year that is not a leap year.
    # @param year [Integer]
    # @param race_date [Date]
    # @return [Date] A date at most 3 days from the anchor, thus there is never a tie.
    def closest_weekday(year, race_date)
      day = race_date.day
      day = 28 if race_date.month == 2 && day == 29 && !Date.leap?(year)
      anchor = Date.new(year, race_date.month, day)
      (-3..3).map { |offset| anchor + offset }.find { |date| date.wday == race_date.wday }
    end

    # The dates to compare: one in each year before the race, newest first. A date that is not
    # before today is passed over, and the next year back takes its place.
    # @param race_date [Date]
    # @param today [Date] The date of today at the location.
    # @param count [Integer] The number of dates.
    # @return [Array<Date>]
    def past_dates(race_date, today:, count: 5)
      dates = []
      year = race_date.year - 1
      while dates.size < count
        date = closest_weekday(year, race_date)
        dates << date if date < today
        year -= 1
      end
      dates
    end
  end
end
