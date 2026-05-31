# Bearer-token authentication for the write endpoints (e.g. POST /api/location). Validates
# the `Authorization: Bearer <token>` header against the API_TOKEN env var with a
# constant-time comparison.
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
