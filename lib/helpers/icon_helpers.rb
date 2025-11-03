require 'humanize'

module IconHelpers
  # Returns the SVG for a specified icon.
  # @param family [String] The icon's Font Awesome family (e.g., "classic", "solid", "thin").
  # @param style [String] The icon's Font Awesome style within the family (e.g., "brands").
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String] The SVG content for the icon.
  def icon_svg(family, style, icon_id)
    data.icons.dig(family, style)&.find { |i| i.id == icon_id }&.svg
  end

  # Returns the SVG for the clock icon closest to the given time.
  # @param datetime [DateTime] The time to be represented by the clock icon.
  # @param family [String] The icon's Font Awesome family (default: "classic").
  # @param style [String] The icon's Font Awesome style within the family (default: "light").
  # @return [String] The SVG content for the clock icon.
  def clock_icon_svg(datetime, family = "classic", style = "light")
    # Extract hours and minutes
    hours = datetime.hour % 12  # Convert 24h to 12h format (12 becomes 0)
    hours = 12 if hours == 0
    minutes = datetime.min

    # Round to the closest time slot
    if minutes < 15
      suffix = "" # Round down to the hour
    elsif minutes < 45
      suffix = "thirty" # Round to half-past
    else
      hours = (hours + 1) % 12 # Round up to the next hour
      hours = 12 if hours == 0
      suffix = ""
    end

    icon_id = if hours == 4 && suffix.blank?
      "clock" # There's no clock-four, it's just block.
    else
      ["clock", hours.humanize, suffix].reject(&:blank?).join("-")
    end

    icon_svg(family, style, icon_id)
  end
end
