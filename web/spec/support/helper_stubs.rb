# Collaborators normally mixed in from other helper modules, pinned here so helpers can be
# exercised in isolation. Defined as real methods (not stubs) so `verify_partial_doubles`
# doesn't reject methods the example group object doesn't implement. Groups that need
# different behavior can redefine either method locally.
RSpec.shared_context 'default helper stubs' do
  def full_url(path, params = {})
    query = params.present? ? "?#{URI.encode_www_form(params)}" : ''
    "https://example.com#{path}#{query}"
  end

  # Passthrough sanitize — the real one runs the markdown pipeline, which these specs don't need.
  def sanitize(text, **)
    text
  end
end
