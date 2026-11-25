require "date"
require "yaml"

# Makes a blog post into a Markdown document, which the build writes beside its HTML as `index.md`.
# This follows the llms.txt convention for a page URL with no file name.
module EntryMarkdownHelpers
  # Gives the path of the Markdown document of a post. config.rb calls this before the helpers load.
  # @param path [String] The source path of the post, for example `/2024/01/01/post/index.html`.
  # @return [String] The path of its Markdown document, for example `/2024/01/01/post/index.md`.
  def self.markdown_path(path)
    path.sub(/index\.html\z/, "index.md")
  end

  # @return [String] The path of the Markdown document of the post.
  def entry_markdown_path(entry)
    EntryMarkdownHelpers.markdown_path(entry.path)
  end

  # Renders a post as Markdown: front matter, the title as a heading, the intro, the body, and the
  # affiliate disclosure.
  # @param entry [Object] An Article or a Short.
  # @return [String] The Markdown document, with a newline at the end.
  def entry_markdown(entry)
    url = full_url(entry.path)
    title = sanitize(entry.title)
    front_matter = {
      "title" => title,
      "url" => url,
      "published" => published_datetime(entry).iso8601,
      "summary" => sanitize(entry.summary)
    }.compact
    sections = [
      "# #{title}",
      render_markdown_body(entry.intro, base_url: url),
      render_markdown_body(entry.body, base_url: url),
      (html_to_markdown(affiliate_links_disclosure(entry)) if show_affiliate_links_disclosure?(entry))
    ].compact_blank

    "#{front_matter.to_yaml(line_width: -1)}---\n\n#{sections.join("\n\n")}\n"
  end
end
