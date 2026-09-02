# Refuses a request body that is larger than the path permits, before any code reads it. Puma
# buffers a large body to the disk, but `request.raw_post` and the form parser then read it into
# memory, on a 512MB machine with three threads. The webhook path reads the full body two times
# before any check of its signature.
#
# It reads CONTENT_LENGTH only. Puma reads a chunked body to its end and sets that header, thus
# no body reaches this code with no length.
class RequestBodyLimit
  # The most bytes for each path prefix. The first match wins. The course-map upload permits
  # MAX_FILES GPX files of MAX_BYTES in total, and the other paths take a form or a small JSON.
  # ⚠️ Plain integers: this file loads before ActiveSupport adds `megabytes` to Integer.
  MEGABYTE = 1024 * 1024
  LIMITS = [
    [ "/course-maps", 32 * MEGABYTE ],
    [ "/api/icons", MEGABYTE / 4 ],
    [ "/social", MEGABYTE / 4 ],
    [ "/webhooks/", MEGABYTE ]
  ].freeze
  DEFAULT_LIMIT = 64 * 1024

  BODY_METHODS = %w[POST PUT PATCH].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless BODY_METHODS.include?(env["REQUEST_METHOD"])

    length = env["CONTENT_LENGTH"].to_i
    return @app.call(env) if length <= limit_for(env["PATH_INFO"].to_s)

    [ 413, { "content-type" => "text/plain; charset=utf-8" }, [ "413 Content Too Large\n" ] ]
  end

  # @param path [String] The request path.
  # @return [Integer] The most bytes that the path permits.
  def limit_for(path)
    LIMITS.find { |prefix, _limit| path.start_with?(prefix) }&.last || DEFAULT_LIMIT
  end
end
