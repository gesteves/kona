# The double of an upstream answer, for a spec that stubs `HTTParty`.
module HttpDoubles
  # @param body [Object] The body. It goes out as JSON.
  # @param success [Boolean] The value of `success?`.
  # @param code [Integer] The HTTP status.
  # @return [RSpec::Mocks::InstanceVerifyingDouble] A double of `HTTParty::Response`.
  def http_response(body, success: true, code: 200)
    instance_double(HTTParty::Response, success?: success, code: code, body: body.to_json, request: nil)
  end
end

RSpec.configure do |config|
  config.include HttpDoubles
end
