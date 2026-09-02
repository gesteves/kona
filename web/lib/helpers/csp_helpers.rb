require "base64"
require "digest"
require "nokogiri"
require "set"

# The parts of the Content-Security-Policy in source/headers.erb that the content decides. A post
# can embed a video or a social post, and the hosts of those embeds change with the content. Thus
# the build reads them from the bodies and writes them into the policy, and a new type of embed
# needs no edit here.
module CspHelpers
  # The hosts that each page needs. Turnstile puts a frame and a script on the contact page.
  CSP_BASE_HOSTS = %w[https://challenges.cloudflare.com].freeze

  # The one inline script of the site. It is one text, thus the policy can name its hash, and
  # `script-src` needs no 'unsafe-inline'. partials/_analytics.html.erb renders it.
  # @return [String] The JavaScript, with no element around it.
  def plausible_init_script
    "window.plausible = window.plausible || function () { (window.plausible.q = window.plausible.q || []).push(arguments) };\n" \
      "window.plausible.init = window.plausible.init || function (i) { window.plausible.o = i || {} };\n" \
      "plausible.init({ autoCapturePageviews: false, endpoint: '#{plausible_event_path}' });"
  end

  # @return [String] The CSP hash source of plausible_init_script.
  def plausible_init_script_hash
    "'sha256-#{Base64.strict_encode64(Digest::SHA256.digest(plausible_init_script))}'"
  end

  # The origins of the iframes and the scripts in each Contentful body.
  #
  # ⚠️ An embed script makes its own iframe from its own host, and the build cannot see that
  # iframe. Thus each script host is also a frame host.
  # @return [Hash{Symbol => Array<String>}] `:frame` and `:script`, each sorted.
  def embed_origins
    memoize_by_collection(:embed_origins, data.articles) do
      frames = Set.new
      scripts = Set.new
      bodies = (Array(data.articles) + Array(data.pages)).flat_map { |entry| [ entry.body, entry.intro ] }.compact
      bodies.each do |body|
        doc = Nokogiri::HTML::DocumentFragment.parse(body)
        doc.css("iframe[src]").each { |node| frames << embed_origin(node["src"]) }
        doc.css("script[src]").each { |node| scripts << embed_origin(node["src"]) }
      end
      frames.merge(scripts)
      { frame: frames.compact.sort, script: scripts.compact.sort }
    end
  end

  # @return [Array<String>] The sources of `frame-src`.
  def csp_frame_src
    (CSP_BASE_HOSTS + embed_origins[:frame]).uniq
  end

  # @return [Array<String>] The sources of `script-src`.
  def csp_script_src
    ([ "'self'", plausible_init_script_hash ] + CSP_BASE_HOSTS + embed_origins[:script]).uniq
  end

  private

  # @param url [String, nil] The `src` of an element. It can have no scheme.
  # @return [String, nil] The origin, with the https scheme, or nil for a URL with no host.
  def embed_origin(url)
    value = url.to_s.strip
    value = "https:#{value}" if value.start_with?("//")
    uri = URI.parse(value)
    return unless uri.is_a?(URI::HTTP) && uri.host.present?

    "https://#{uri.host.downcase}"
  rescue URI::InvalidURIError
    nil
  end
end
