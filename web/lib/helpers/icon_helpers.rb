require 'humanize'

module IconHelpers
  # Looks up an icon's SVG, marked decorative — icons always sit beside a text label or an
  # aria-labelled parent.
  # @param family [String] The Font Awesome family, e.g. "classic".
  # @param style [String] The style within the family, e.g. "solid".
  # @param icon_id [String] The icon's id.
  # @return [String, nil] The SVG, or nil when the icon isn't in data/icons.json.
  def icon_svg(family, style, icon_id)
    svg = data.icons.dig(family, style)&.find { |i| i.id == icon_id }&.svg
    svg&.sub("<svg", '<svg aria-hidden="true" focusable="false"')
  end

  # Looks up the clock icon nearest the given time, rounded to the closest half hour.
  # @param datetime [DateTime] The time to represent.
  # @param family [String] The Font Awesome family.
  # @param style [String] The style within the family.
  # @return [String, nil] The SVG.
  def clock_icon_svg(datetime, family = "classic", style = "light")
    hours = datetime.hour % 12
    hours = 12 if hours == 0
    minutes = datetime.min

    if minutes < 15
      suffix = ""
    elsif minutes < 45
      suffix = "thirty"
    else
      hours = (hours + 1) % 12
      hours = 12 if hours == 0
      suffix = ""
    end

    icon_id = if hours == 4 && suffix.blank?
      "clock" # There is no clock-four; the plain clock icon reads four o'clock.
    else
      ["clock", hours.humanize, suffix].reject(&:blank?).join("-")
    end

    icon_svg(family, style, icon_id)
  end
end
