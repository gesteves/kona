# Finds the links between the entries of this site in the text of each entry. RelatedArticles
# reads them: a link that the author wrote is a strong sign that two entries are related, and the
# lexical index cannot see it, because `markdown_to_plain_text` removes each URL before the tokens.
#
# ⚠️ Never write the host name of the site here. It comes from SITE_URL.
class ArticleLinks
  # An absolute URL, up to the first character that ends one in Markdown or in HTML.
  URL_PATTERN = %r{https?://[^\s)"'<>]+}
  # The path of an entry: /YYYY/MM/DD/slug. The slash at the end is optional here, and
  # `normalize` adds it.
  PATH_PATTERN = %r{/20\d{2}/\d{2}/\d{2}/[\w-]+}
  # A root-relative path in the text, and not the path part of a URL of another site.
  RELATIVE_PATH_PATTERN = %r{(?<![\w/])(#{PATH_PATTERN.source})}

  # @param corpus [Hash{String=>Hash}] Contentful id => { intro:, body: }, as raw Markdown.
  # @param paths [Hash{String=>String}] Contentful id => the path of that entry. A link to a path
  #   that is absent from this map is ignored, thus a draft is never a target.
  # @param site_url [String, nil] The URL of the site. A URL with another host is ignored.
  def initialize(corpus, paths, site_url: ENV["SITE_URL"])
    @host = host_of(site_url)
    @ids_by_path = (paths || {}).each_with_object({}) do |(id, path), acc|
      acc[normalize(path)] = id if path.present?
    end
    @links = build(corpus || {})
  end

  # @return [Boolean] True when either entry links to the other one.
  def linked?(a_id, b_id)
    links_of(a_id).include?(b_id) || links_of(b_id).include?(a_id)
  end

  # @return [Array<String>] The ids that this entry links to.
  def links_of(id)
    Array(@links[id])
  end

  private

  # @return [Hash{String=>Array<String>}] id => the ids that its text links to.
  def build(corpus)
    corpus.each_with_object({}) do |(id, fields), acc|
      fields = fields || {}
      text = [ fields[:intro], fields[:body] ].compact.join("\n")
      targets = paths_in(text).filter_map { |path| @ids_by_path[path] }.uniq - [ id ]
      acc[id] = targets if targets.any?
    end
  end

  # The paths of this site in a text: the path of each URL with the host of the site, and each
  # root-relative path outside a URL.
  # @return [Array<String>] Normalized paths.
  def paths_in(text)
    found = []
    rest = text.gsub(URL_PATTERN) do |url|
      path = site_path(url)
      found << path if path
      " "
    end
    rest.scan(RELATIVE_PATH_PATTERN) { |match| found << normalize(match.first) }
    found.uniq
  end

  # @return [String, nil] The normalized path of a URL of this site, or nil for another site.
  def site_path(url)
    uri = URI.parse(url)
    return if @host.nil? || bare_host(uri.host) != @host

    match = uri.path.to_s.match(/\A#{PATH_PATTERN.source}/)
    normalize(match[0]) if match
  rescue URI::InvalidURIError
    nil
  end

  def host_of(site_url)
    return if site_url.blank?

    bare_host(URI.parse(site_url).host)
  rescue URI::InvalidURIError
    nil
  end

  # A host with no "www." and in lower case, thus the two forms of one site are equal.
  def bare_host(host)
    host.to_s.downcase.delete_prefix("www.").presence
  end

  # The form of ArticleAttributes.path: no index.html, and a slash at the end.
  def normalize(path)
    clean = path.to_s.sub(%r{/index\.html\z}, "")
    clean.end_with?("/") ? clean : "#{clean}/"
  end
end
