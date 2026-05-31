require "nokogiri"

module MarkupHelper
  # Renders a tag carrying the data-* attributes that drive the client-side unit-conversion
  # Stimulus controller (metric/imperial toggle). Defaults to a <span>.
  def units_tag(metric, imperial, tag = :span)
    content_tag tag.to_sym, "data-controller": "units", "data-units-imperial-value": imperial, "data-units-metric-value": metric, title: "#{metric} | #{imperial}" do
      metric
    end
  end

  # Renders an event's Markdown body to HTML for the upcoming-races widget. This is a
  # deliberately minimal subset of the static site's render_body: events are short prose with
  # no images, tables, iframes, or embeds, so it skips the asset/figure/srcset/blurhash
  # machinery (which is welded to the build-time asset index anyway) and does only the two
  # lightweight transforms events actually use — unit-conversion spans and external links.
  # Any Markdown image/table, were one ever added, degrades to a plain element.
  # @param text [String, nil]
  # @return [String, nil]
  def render_event_body(text)
    html = markdown_to_html(text)
    return if html.blank?
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    add_unit_data_attributes(doc)
    open_external_links_in_new_tabs(doc)
    doc.to_html
  end

  private

  # Swaps `<span data-imperial="…">metric</span>` for the unit-conversion markup, so Contentful
  # authors can write a simple span and get the metric/imperial toggle.
  def add_unit_data_attributes(doc)
    doc.css("[data-imperial]").each do |element|
      replacement = units_tag(element.text, element["data-imperial"], element.name.to_sym)
      element.replace(Nokogiri::HTML::DocumentFragment.parse(replacement))
    end
    doc
  end

  # Opens absolute links in a new tab. Event descriptions only ever link to external race
  # sites, so every absolute link is treated as external (no same-host exception needed).
  def open_external_links_in_new_tabs(doc)
    doc.css("a").each do |a|
      href = a["href"]
      next unless href&.start_with?("http://", "https://")
      a["rel"] = "noopener"
      a["target"] = "_blank"
    end
    doc
  end
end
