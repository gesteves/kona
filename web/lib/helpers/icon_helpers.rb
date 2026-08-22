require "humanize"

module IconHelpers
  # Finds the SVG of an icon, with a mark that says it is decoration. Each icon is always beside a
  # text label or in a parent with an aria-label.
  # @param family [String] The Font Awesome family, for example "classic".
  # @param style [String] The style in that family, for example "solid".
  # @param icon_id [String] The id of the icon.
  # @return [String, nil] The SVG, or nil if data/icons.json does not have the icon.
  def icon_svg(family, style, icon_id)
    svg = icon_index[[ family, style, icon_id ]]
    svg&.sub("<svg", '<svg aria-hidden="true" focusable="false"')
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
end
