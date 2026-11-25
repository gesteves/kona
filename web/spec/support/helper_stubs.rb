# spec_helper.rb includes each helper module, thus `full_url` and `sanitize` already exist, and
# this context overrides them with simple results. Only `url_for` is absent: Middleman supplies
# it. `url_for` is a true method, because `verify_partial_doubles` refuses a stub of a method
# that the object does not have. A group that needs a different result can define each one again.
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
