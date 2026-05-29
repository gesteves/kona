module IconsHelper
  # Returns the SVG markup for a Font Awesome icon.
  # @param family [String] The icon's family (e.g., "classic").
  # @param style [String] The icon's style within the family (e.g., "light").
  # @param icon_id [String] The icon's identifier (e.g., "person-running").
  # @return [String, nil] The SVG markup for the icon.
  def icon_svg(family, style, icon_id)
    (@font_awesome ||= FontAwesome.new).svg(family, style, icon_id)
  end
end
