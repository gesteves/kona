module IconHelpers
  # Returns the SVG for a specified icon.
  # @param family [String] The icon's Font Awesome family (e.g., "classic", "solid", "thin").
  # @param style [String] The icon's Font Awesome style within the family (e.g., "brands").
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String] The SVG content for the icon, or an empty string if not found.
  def icon_svg(family, style, icon_id)
    data.icons.dig(family, style)&.find { |i| i.id == icon_id }&.svg
  end
end
