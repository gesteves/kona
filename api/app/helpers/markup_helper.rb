module MarkupHelper
  # Renders a tag carrying the data-* attributes that drive the client-side unit-conversion
  # Stimulus controller (metric/imperial toggle). Defaults to a <span>.
  def units_tag(metric, imperial, tag = :span)
    content_tag tag.to_sym, "data-controller": "units", "data-units-imperial-value": imperial, "data-units-metric-value": metric, title: "#{metric} | #{imperial}" do
      metric
    end
  end
end
