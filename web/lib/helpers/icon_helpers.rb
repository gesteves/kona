require "humanize"

module IconHelpers
  # The marks of a decorative icon. Each icon is always beside a text label or in a parent with an
  # aria-label.
  ICON_ATTRIBUTES = 'aria-hidden="true" focusable="false"'.freeze

  # A `<use>` reference to an icon symbol, in a rendered HTML string.
  ICON_REFERENCE = /href="#icon-([a-z]+)-([a-z]+)-([^"]+)"/

  # Makes the SVG of an icon: a `<use>` of its symbol, with the marks that say it is decoration.
  #
  # ⚠️ The paths of the icon are not here. They go in the sprite at the end of the body, one time
  # for each icon that the page uses, through #icon_symbols. A listing page renders one icon
  # sixty times, and each copy of the paths was a large part of that page.
  # @param family [String] The Font Awesome family, for example "classic".
  # @param style [String] The style in that family, for example "solid".
  # @param icon_id [String] The id of the icon.
  # @return [String, nil] The SVG, or nil if data/icons.json does not have the icon.
  def icon_svg(family, style, icon_id)
    key = [ family, style, icon_id ]
    svg = icon_index[key]
    return if svg.nil?

    record_icon(key)
    open_tag = svg[/\A<svg[^>]*>/]
    %(#{open_tag.sub("<svg", "<svg #{ICON_ATTRIBUTES}")}<use href="##{icon_symbol_id(key)}"></use></svg>)
  end

  # The `<symbol>` of each icon that this page rendered, for the sprite in the layout.
  # @return [String] The symbols, with no wrapper.
  def icon_symbols
    (@icon_sprite_keys || {}).keys.filter_map do |key|
      svg = icon_index[key]
      next if svg.nil?

      view_box = svg[/viewBox="([^"]*)"/, 1]
      inner = svg[/\A<svg[^>]*>(.*)<\/svg>\s*\z/m, 1]
      %(<symbol id="#{icon_symbol_id(key)}" viewBox="#{view_box}">#{inner}</symbol>)
    end.join
  end

  # Records each icon that a rendered HTML string uses, for #icon_symbols.
  #
  # ⚠️ The render memo of MarkupHelpers calls this for a body that another page rendered. Without
  # it, the sprite of this page would omit the icons of that body.
  # @param html [String, nil]
  # @return [void]
  def record_icons_in(html)
    html.to_s.scan(ICON_REFERENCE) { |family, style, icon_id| record_icon([ family, style, icon_id ]) }
  end

  # The SVG of each icon, with [family, style, id] as the key. The app makes this one time for each
  # build.
  #
  # This is an index and not a `find` over data.icons, as ImageHelpers#asset_index also is. Each item
  # is a Hashie::Mash object, thus each `.id` in a scan is a method_missing call, and a listing page
  # renders a few hundred icons against approximately 90 candidates for each one. A measurement
  # showed no change to the build time, because the build is not slow here. Thus this is clean code
  # and not a speed improvement, and do not say that it is one.
  # @return [Hash] The [family, style, id] tuples and their SVG markup.
  def icon_index
    memoize_by_collection(:icon_index, data.icons) do
      data.icons.each_with_object({}) do |(family, styles), index|
        styles.each do |style, icons|
          icons.each { |icon| index[[ family, style, icon.id ]] = icon.svg }
        end
      end
    end
  end

  # Finds the clock icon that is nearest to the given time, at the nearest half hour.
  # @param datetime [DateTime] The time to show.
  # @param family [String] The Font Awesome family.
  # @param style [String] The style in that family.
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
      [ "clock", hours.humanize, suffix ].reject(&:blank?).join("-")
    end

    icon_svg(family, style, icon_id)
  end

  private

  # @param key [Array<String>] [family, style, id].
  # @return [String] The DOM id of the symbol.
  def icon_symbol_id(key) = "icon-#{key.join('-')}"

  # Keeps the key of an icon for the sprite of this page. The keys stay in the order of the first
  # render.
  # @param key [Array<String>]
  # @return [void]
  def record_icon(key)
    (@icon_sprite_keys ||= {})[key] = true
  end
end
