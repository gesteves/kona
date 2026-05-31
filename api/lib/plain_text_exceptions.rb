# Renders framework-level 4xx/5xx responses as plain text, replacing Rails' default static
# public/*.html error pages — appropriate for a headless, machine-only API. Wired up via
# config.exceptions_app; ActionDispatch::ShowExceptions invokes it with PATH_INFO set to
# "/<status>".
class PlainTextExceptions
  def self.call(env)
    request = ActionDispatch::Request.new(env)
    status  = request.path_info[1..].to_i
    status  = 500 unless status.between?(400, 599)
    message = Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error")
    body    = "#{status} #{message}\n"

    headers = { "content-type" => "text/plain; charset=utf-8" }
    return [status, headers.merge("content-length" => "0"), []] if request.head?

    [status, headers.merge("content-length" => body.bytesize.to_s), [body]]
  end
end
