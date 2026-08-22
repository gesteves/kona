module TimeHelper
  # Formats a timestamp in the given timezone as "HH:MM <abbr>AM</abbr>". It puts the AM or the PM
  # in an <abbr> tag. It returns a string that is not HTML-safe, thus render it with `raw`.
  # @param time [String, Time, nil] The time to format.
  # @param time_zone [String, nil] The IANA timezone id.
  # @return [String, nil]
  def time_with_meridiem_abbr(time, time_zone)
    return if time.blank? || time_zone.blank?

    meridiem_abbr(Time.parse(time.to_s).in_time_zone(time_zone).strftime("%I:%M %p"))
  end

  # Puts the AM or the PM in an <abbr> tag. The time formatter and the weather formatter share it.
  #
  # ⚠️ The match needs a word limit, and the tag needs a title. With no word limit, it changed each
  # text with "am" or "pm" in it, for example "Amsterdam" and "campus", and this method is public on
  # a helper that WeatherSummaryPresenter includes, and that class makes sentences. An <abbr> with
  # no title also gives a screen reader no full form to speak.
  # @param text [String]
  # @return [String]
  def meridiem_abbr(text)
    text.gsub(/\b(am|pm)\b/i) do
      meridiem = Regexp.last_match(1)
      title = meridiem.downcase == "am" ? "ante meridiem" : "post meridiem"
      %(<abbr title="#{title}">#{meridiem}</abbr>)
    end
  end
end
