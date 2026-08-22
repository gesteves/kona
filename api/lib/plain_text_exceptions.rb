# Renders each 4xx and 5xx response from the framework as plain text, in place of the default static
# public/*.html error pages of Rails. That is correct for an API for machines only, with no user
# interface. config.exceptions_app names it, and ActionDispatch::ShowExceptions calls it with
# PATH_INFO set to "/<status>".
class PlainTextExceptions
  def self.call(env)
    request = ActionDispatch::Request.new(env)
    status  = request.path_info[1..].to_i
    status  = 500 unless status.between?(400, 599)
    message = Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error")
    body    = "#{status} #{message}\n"

    headers = { "content-type" => "text/plain; charset=utf-8" }
    return [ status, headers.merge("content-length" => "0"), [] ] if request.head?

    [ status, headers.merge("content-length" => body.bytesize.to_s), [ body ] ]
  end
end
