module IconsHelper
  # The SVG markup of a Font Awesome icon.
  # @param family [String] The family of the icon, for example "classic".
  # @param style [String] The style of the icon in that family, for example "light".
  # @param icon_id [String] The identifier of the icon, for example "person-running".
  # @return [String, nil] The SVG markup of the icon.
  def icon_svg(family, style, icon_id)
    # The code keeps the value for each request, in the helper context. A fragment uses the same
    # icon id more than one time, for example arrow-down for each stat, and each lookup with no
    # stored value is one request to Redis.
    @icon_svg_cache ||= {}
    key = [ family, style, icon_id ]
    @icon_svg_cache[key] = (@font_awesome ||= FontAwesome.new).svg(family, style, icon_id) unless @icon_svg_cache.key?(key)

    # These icons are decoration. Hide them from the assistive technology, because each one is
    # always beside a text label or in a parent with an aria-label. `focusable="false"` stops the
    # old Edge and IE from a tab stop on the SVG.
    @icon_svg_cache[key]&.sub("<svg", '<svg aria-hidden="true" focusable="false"')
  end

  # The SVG markup of a Font Awesome icon, with a `slot` attribute. This is for a Web Awesome
  # component that takes its icon in a named slot: `start` or `end` on <wa-button>, and `icon` on
  # <wa-callout>. It returns a safe buffer, thus a view needs no `raw`. Without `raw`, a plain String
  # renders as text on the page.
  # @param family [String] The family of the icon, for example "classic".
  # @param style [String] The style of the icon in that family, for example "light".
  # @param icon_id [String] The identifier of the icon, for example "trash".
  # @param slot [String] The slot of the component for the icon.
  # @return [ActiveSupport::SafeBuffer, nil] The SVG markup, or nil if the code cannot find the
  #   icon.
  def slotted_icon_svg(family, style, icon_id, slot: "start")
    svg = icon_svg(family, style, icon_id)
    raw svg.sub("<svg", %(<svg slot="#{ERB::Util.h(slot)}")) if svg
  end

  # The hour as an integer (1 to 12) → the word, for the clock icon ids: clock-three,
  # clock-three-thirty, and more.
  CLOCK_NUMBER_WORDS = %w[zero one two three four five six seven eight nine ten eleven twelve].freeze

  # The SVG of the clock icon that is nearest to the given time. This is the same as the
  # clock_icon_svg of the static site. The number words are in this file, thus the app needs no
  # humanize gem.
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
      [ "clock", CLOCK_NUMBER_WORDS[hours], suffix ].reject(&:blank?).join("-")
    end

    icon_svg(family, style, icon_id)
  end
end
