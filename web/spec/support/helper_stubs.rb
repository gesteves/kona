# Collaborators normally mixed in from other helper modules, pinned here so helpers can be
# exercised in isolation. Defined as real methods (not stubs) so `verify_partial_doubles`
# doesn't reject methods the example group object doesn't implement. Groups that need
# different behavior can redefine either method locally.
RSpec.shared_context 'default helper stubs' do
  def full_url(path, params = {})
    query = params.present? ? "?#{URI.encode_www_form(params)}" : ''
    "https://example.com#{url_for(path)}#{query}"
  end

  # Stand-in for Middleman's sitemap-aware url_for. The only behavior these specs care about is
  # the one `activate :directory_indexes` gives it: a source path's `index.html` is dropped, so
  # `/2024/01/01/post/index.html` is served (and linked to) as `/2024/01/01/post/`.
  def url_for(path, _options = {})
    path.to_s.sub(%r{index\.html\z}, '')
  end

  # Passthrough sanitize — the real one runs the markdown pipeline, which these specs don't need.
  def sanitize(text, **)
    text
  end
end
