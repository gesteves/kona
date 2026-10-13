require "yaml"

# Makes the about page into the portable Markdown of AboutSpec, which the build writes to
# /.well-known/about.md.
module AboutHelpers
  # The slug of the about page. ⚠️ Use the slug and not the sys.id, because the sys.id is not stable.
  ABOUT_PAGE_SLUG = "about".freeze

  # @param pages [Array] The pages from Contentful.
  # @return [Object, nil] The published about page, or nil when there is none.
  def self.about_page(pages)
    pages.find { |page| page.slug == ABOUT_PAGE_SLUG && !page.draft }
  end

  # Renders the about page as AboutSpec Markdown: front matter with a `summary`, then the body.
  # There is no title heading, because the reader shows the document in its own "About" tab.
  # @param page [Object] The about page.
  # @return [String] The Markdown document, with a newline at the end.
  def about_markdown(page)
    summary = sanitize(page.summary)
    front_matter = "#{{ "summary" => summary }.to_yaml(line_width: -1)}---\n\n" if summary.present?
    sections = [
      render_markdown_body(page.body, base_url: full_url(page.path)),
      (html_to_markdown(affiliate_links_disclosure(page)) if show_affiliate_links_disclosure?(page))
    ].compact_blank

    "#{front_matter}#{sections.join("\n\n")}\n"
  end
end
