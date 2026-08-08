module TimeHelper
  # Formats a timestamp in the given timezone as "HH:MM <abbr>AM</abbr>", wrapping the
  # meridiem in an <abbr> tag. Returns an HTML-unsafe string (render with `raw`).
  # @param time [String, Time, nil] The time to format.
  # @param time_zone [String, nil] The IANA timezone id.
  # @return [String, nil]
  def time_with_meridiem_abbr(time, time_zone)
    return if time.blank? || time_zone.blank?

    meridiem_abbr(Time.parse(time.to_s).in_time_zone(time_zone).strftime("%I:%M %p"))
  end

  # Wraps the meridiem (AM/PM) in an <abbr> tag. Shared by the time and weather formatters.
  #
  # ⚠️ Word-bounded, and titled. Unbounded, it mangled any prose containing "am"/"pm" —
  # "Amsterdam", "campus" — and this is public on a helper mixed into WeatherSummaryPresenter,
  # which composes sentences. A title-less <abbr> also gives a screen reader nothing to expand.
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
