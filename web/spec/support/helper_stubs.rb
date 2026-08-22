# The methods that other helper modules usually supply. This file defines them, thus a test can run
# one helper alone. They are true methods and not stubs, thus `verify_partial_doubles` does not
# refuse a method that the example group object does not have. A group that needs a different result
# can define either method again.
RSpec.shared_context 'default helper stubs' do
  def full_url(path, params = {})
    query = params.present? ? "?#{URI.encode_www_form(params)}" : ''
    "https://example.com#{url_for(path)}#{query}"
  end

  # A replacement for the url_for of Middleman, which reads the sitemap. These specs need one
  # behavior only, which `activate :directory_indexes` gives: the code removes the `index.html` of a
  # source path. Thus the app serves `/2024/01/01/post/index.html` as `/2024/01/01/post/`, and each
  # link uses that path.
  def url_for(path, _options = {})
    path.to_s.sub(%r{index\.html\z}, '')
  end

  # A sanitize that changes nothing. The true method runs the Markdown pipeline, and these specs do
  # not need it.
  def sanitize(text, **)
    text
  end
end
