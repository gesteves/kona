require "ipaddr"
require "resolv"

# Tells if a URL names a host on the public internet. The code reads a page, or a picture, that
# the owner or another site names, thus a URL here can name this machine, the private network of
# fly, or the metadata service of the cloud. The check resolves the host and refuses each address
# outside the public ranges, and it refuses a port that is not the port of a web server.
#
# ⚠️ Apply it to each redirect hop as well: a public page can redirect to a private address.
# ApplicationService#download does that. The check resolves the name one time, and the request
# resolves it again, thus a name whose answer changes between the two can still reach a private
# address. That is a small window, and this app makes no request that a stranger starts.
module PublicAddress
  PRIVATE_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
    192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  # `.internal` is the private DNS of fly, and `.local` is mDNS.
  PRIVATE_HOST_SUFFIXES = %w[.internal .local .localhost].freeze

  PUBLIC_PORTS = [ 80, 443 ].freeze

  # @param url [String, nil]
  # @return [Boolean] True for an http or https URL on a public host and a web port.
  def self.public_url?(url)
    uri = URI.parse(url.to_s)
    return false unless uri.is_a?(URI::HTTP) && uri.host.present?
    return false unless PUBLIC_PORTS.include?(uri.port)

    public_host?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  # @param host [String] A host name or an IP literal.
  # @return [Boolean] True when each address of the host is public.
  def self.public_host?(host)
    name = host.to_s.downcase.delete_prefix("[").delete_suffix("]").delete_suffix(".")
    return false if name.blank? || name == "localhost"
    return false if PRIVATE_HOST_SUFFIXES.any? { |suffix| name.end_with?(suffix) }

    found = addresses(name)
    found.any? && found.all? { |address| public_ip?(address) }
  end

  # @param name [String] A host name or an IP literal.
  # @return [Array<IPAddr>] Each address of the host, or an empty list when none resolves.
  def self.addresses(name)
    return [ IPAddr.new(name) ] if name.match?(/\A[0-9a-f.:]+\z/i)

    Resolv.getaddresses(name).map { |address| IPAddr.new(address) }
  rescue IPAddr::Error, Resolv::ResolvError
    []
  end

  # @param address [IPAddr]
  # @return [Boolean] True when the address is outside each private range.
  def self.public_ip?(address)
    address = address.native if address.ipv4_mapped?
    PRIVATE_RANGES.none? { |range| range.include?(address) }
  end
end
