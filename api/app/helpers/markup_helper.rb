require "nokogiri"

module MarkupHelper
  # Renders a tag wired to the units Stimulus controller. Uses the non-block content_tag form
  # on purpose — the block form needs an output buffer, which the presenters don't have.
  def units_tag(metric, imperial, tag = :span)
    content_tag tag.to_sym, metric, "data-controller": "units", "data-units-imperial-value": imperial, "data-units-metric-value": metric, title: "#{metric} | #{imperial}"
  end

  # Renders a card's Markdown body to HTML. A deliberately minimal subset of the static site's
  # render_body: card bodies are short prose, so this skips the asset, figure, srcset, and
  # blurhash machinery — which is welded to the build-time asset index anyway — and does only
  # the two transforms these bodies use. A Markdown image or table degrades to a plain element.
  # @param text [String, nil] The Markdown.
  # @return [String, nil] The HTML, or nil for blank input.
  def render_summary_body(text)
    html = markdown_to_html(text)
    return if html.blank?
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    add_unit_data_attributes(doc)
    open_external_links_in_new_tabs(doc)
    doc.to_html
  end

  private

  # Rewrites the `data-imperial` shorthand authors write in Contentful into the units
  # controller's attributes.
  def add_unit_data_attributes(doc)
    doc.css("[data-imperial]").each do |element|
      replacement = units_tag(element.text, element["data-imperial"], element.name.to_sym)
      element.replace(Nokogiri::HTML::DocumentFragment.parse(replacement))
    end
    doc
  end

  # Opens absolute links in a new tab. These bodies only ever link to external race sites, so
  # no same-host exception is needed.
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
