require "resolv"

# Checks that the domain of an email address can receive mail, with one DNS lookup of its MX
# records. Thus the contact form refuses a made-up domain and a typo, for example `gmail.con`. It
# cannot find a made-up mailbox on a real domain.
#
# It is not an ApplicationService, because it makes no HTTP call.
module EmailDomain
  # The DNS lookup did not give an answer in time.
  class LookupError < StandardError; end

  # The time for each attempt of the lookup, in seconds. The lookup runs in the request.
  TIMEOUT_SECONDS = 2

  module_function

  # ⚠️ The domain needs an MX record, and an A record is not sufficient. RFC 5321 permits that
  # fallback, but a made-up or parked domain often has an A record.
  # @param email [String] An address that already matches `URI::MailTo::EMAIL_REGEXP`.
  # @return [Boolean] True if the domain has an MX record that is not a null MX (RFC 7505). False
  #   for a domain that does not exist.
  # @raise [LookupError] If the lookup times out.
  def accepts_mail?(email)
    domain = email.to_s.split("@").last.to_s.downcase
    return false if domain.empty?

    mx_records(domain).any? { |mx| !mx.exchange.to_s.empty? }
  end

  # @param domain [String]
  # @return [Array<Resolv::DNS::Resource::IN::MX>] Empty for NXDOMAIN and for an answer with no MX.
  # @raise [LookupError] If the lookup times out.
  def mx_records(domain)
    # ⚠️ A configuration Hash replaces the system configuration, thus the flag goes into the
    # default Hash. Without the nameservers of resolv.conf, Resolv asks 0.0.0.0 and each lookup
    # times out.
    Resolv::DNS.open(Resolv::DNS::Config.default_config_hash.merge(raise_timeout_errors: true)) do |dns|
      dns.timeouts = TIMEOUT_SECONDS
      # The final period makes the name absolute, thus no search domain adds a second lookup.
      dns.getresources(Resolv::DNS::Name.create("#{domain}."), Resolv::DNS::Resource::IN::MX)
    end
  rescue Resolv::ResolvError, Resolv::ResolvTimeout => e
    raise LookupError, "MX lookup for #{domain} failed: #{e.message}"
  end
end
