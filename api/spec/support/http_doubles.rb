# The double of an upstream answer, for a spec that stubs `HTTParty`.
module HttpDoubles
  # @param body [Object] The body. A String goes out as it is, and each other value goes out as
  #   JSON.
  # @param success [Boolean] The value of `success?`.
  # @param code [Integer] The HTTP status.
  # @return [RSpec::Mocks::InstanceVerifyingDouble] A double of `HTTParty::Response`.
  def http_response(body, success: true, code: 200)
    body = body.to_json unless body.is_a?(String)
    instance_double(HTTParty::Response, success?: success, code: code, body: body, request: nil)
  end

  # Makes each `HTTParty.post` of the example give one answer.
  # @param code [Integer] The HTTP status. The default is 200, or 500 for a failure.
  def stub_http_post(body, success: true, code: success ? 200 : 500)
    allow(HTTParty).to receive(:post).and_return(http_response(body, success: success, code: code))
  end
end

RSpec.configure do |config|
  config.include HttpDoubles
end
