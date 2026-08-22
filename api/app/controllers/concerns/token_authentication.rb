# The bearer-token authentication of the write endpoints, for example POST /api/location. It
# compares the `Authorization: Bearer <token>` header with the API_TOKEN env var, and that comparison
# always takes the same time.
module TokenAuthentication
  extend ActiveSupport::Concern

  private

  def authenticate_bearer_token!
    authenticated = authenticate_with_http_token do |token, _options|
      expected = ENV["API_TOKEN"].to_s
      expected.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
    end

    head :unauthorized unless authenticated
  end
end
