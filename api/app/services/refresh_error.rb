# The record of a refused token refresh. Whoop and Threads both keep one, thus the Connected apps
# page can say that a connection needs attention, and it does not show a green badge for a token
# that is dead.
module RefreshError
  # ⚠️ Record a 4xx only. A 5xx or a timeout means that the service is not available, and not that
  # the token is dead. A mark for those sends the owner to authorize a connection that is good,
  # and the next scheduled refresh recovers by itself.
  # @param code [Integer, String] The HTTP status of the token endpoint.
  # @return [Boolean] True when the service refused the token.
  def self.refused?(code)
    code.to_i.between?(400, 499)
  end

  # @param code [Integer, String]
  # @return [String] The record, as JSON: `{ code:, at: }`.
  def self.encode(code)
    { code: code.to_i, at: Time.current.utc.iso8601 }.to_json
  end

  # @param raw [String, nil] A record from Redis.
  # @return [Hash, nil] `{ code:, at: }`, or nil with no record.
  def self.decode(raw)
    JSON.parse(raw, symbolize_names: true) if raw.present?
  rescue JSON::ParserError
    nil
  end
end
