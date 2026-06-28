require "active_support/security_utils"

# Shared HTTP Basic Auth check for owner-only surfaces: the Whoop OAuth authorize endpoint
# and the Sidekiq web UI. Both gate on the same WHOOP_AUTH_USERNAME / WHOOP_AUTH_PASSWORD
# credentials (for now), so the comparison lives in one place.
module OwnerBasicAuth
  module_function

  # @return [Boolean] true only when both credentials are configured and match, compared in
  #   constant time. The `&` (not `&&`) is deliberate: both comparisons always run so the
  #   response time can't reveal which field was wrong.
  def valid?(username, password)
    expected_user = ENV["WHOOP_AUTH_USERNAME"].to_s
    expected_pass = ENV["WHOOP_AUTH_PASSWORD"].to_s
    return false if expected_user.empty? || expected_pass.empty?

    ActiveSupport::SecurityUtils.secure_compare(username.to_s, expected_user) &
      ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_pass)
  end
end
