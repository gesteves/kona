require "humanize"

module IconHelpers
  # Looks up an icon's SVG, marked decorative — icons always sit beside a text label or an
  # aria-labelled parent.
  # @param family [String] The Font Awesome family, e.g. "classic".
  # @param style [String] The style within the family, e.g. "solid".
  # @param icon_id [String] The icon's id.
  # @return [String, nil] The SVG, or nil when the icon isn't in data/icons.json.
  def icon_svg(family, style, icon_id)
    svg = icon_index[[ family, style, icon_id ]]
    svg&.sub("<svg", '<svg aria-hidden="true" focusable="false"')
  end

  # Every icon's SVG keyed by [family, style, id], built once per build.
  #
  # An index rather than a `find` over data.icons, mirroring ImageHelpers#asset_index: these are
  # Hashie::Mash objects, so every `.id` in a linear scan is a method_missing dispatch, and a
  # listing page renders a few hundred icons against ~90 candidates apiece. Measured, it makes no
  # difference to build time — the build isn't bottlenecked here — so treat this as tidiness, not
  # an optimization, and don't cite it as one.
  # @return [Hash] [family, style, id] tuples mapped to SVG markup.
  def icon_index
    memoize_by_collection(:icon_index, data.icons) do
      data.icons.each_with_object({}) do |(family, styles), index|
        styles.each do |style, icons|
          icons.each { |icon| index[[ family, style, icon.id ]] = icon.svg }
        end
      end
    end
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
      [ "clock", hours.humanize, suffix ].reject(&:blank?).join("-")
    end

    icon_svg(family, style, icon_id)
  end
end
