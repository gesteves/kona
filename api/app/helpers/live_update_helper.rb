module LiveUpdateHelper
  # The absolute URL the embedded markup should refetch itself from on visibilitychange.
  #
  # The static site embeds this API behind CloudFront,
  # but CloudFront forwards the *origin* Host to us, so request.base_url
  # can't be trusted as the public URL. Set PUBLIC_BASE_URL to the public origin so the
  # rendered markup points back at it; fall back to the request host for local/dev.
  # @return [String] e.g. "https://api.giventotri.com/whoop"
  def live_update_url
    base = ENV.fetch("PUBLIC_BASE_URL", request.base_url)
    "#{base}#{request.path}"
  end
end
