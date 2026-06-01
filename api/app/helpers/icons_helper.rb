module IconsHelper
  # Returns the SVG markup for a Font Awesome icon.
  # @param family [String] The icon's family (e.g., "classic").
  # @param style [String] The icon's style within the family (e.g., "light").
  # @param icon_id [String] The icon's identifier (e.g., "person-running").
  # @return [String, nil] The SVG markup for the icon.
  def icon_svg(family, style, icon_id)
    svg = (@font_awesome ||= FontAwesome.new).svg(family, style, icon_id)
    # Decorative icons: hide from assistive tech (they always sit next to a text label or
    # an aria-label'd parent). focusable="false" keeps legacy Edge/IE from tab-stopping the SVG.
    svg&.sub("<svg", '<svg aria-hidden="true" focusable="false"')
  end

  # Integer hour (1–12) → word, for the clock-face icon ids (clock-three, clock-three-thirty, …).
  CLOCK_NUMBER_WORDS = %w[zero one two three four five six seven eight nine ten eleven twelve].freeze

  # Returns the SVG for the clock-face icon closest to the given time. Mirrors the static site's
  # clock_icon_svg; the number words are inlined so no humanize gem is needed.
  # @param datetime [DateTime, Time]
  # @return [String, nil]
  def clock_icon_svg(datetime, family = "classic", style = "light")
    hours = datetime.hour % 12
    hours = 12 if hours.zero?
    minutes = datetime.min

    if minutes < 15
      suffix = ""
    elsif minutes < 45
      suffix = "thirty"
    else
      hours = (hours + 1) % 12
      hours = 12 if hours.zero?
      suffix = ""
    end

    icon_id = if hours == 4 && suffix.blank?
      "clock" # there's no clock-four icon
    else
      ["clock", CLOCK_NUMBER_WORDS[hours], suffix].reject(&:blank?).join("-")
    end

    icon_svg(family, style, icon_id)
  end
end
