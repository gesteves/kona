require 'httparty'
require 'active_support/all'

class Bluesky
  BASE_URL = "https://bsky.social".freeze

  # Initializes a new instance of the Bluesky class.
  def initialize
  end

  # Converts a Bluesky post URL into an at-uri.
  #
  # @param post_url [String] the public Bluesky post URL.
  # @return [String] the at-uri for the post.
  # @raise [ArgumentError] if the post URL is invalid.
  def self.post_url_to_at_uri(post_url)
    cache_key = "bluesky:posts:at-uri:#{post_url.parameterize}"
    at_uri = $redis.get(cache_key)

    return at_uri if at_uri.present?

    # Validate the URL
    uri = URI.parse(post_url)
    return unless uri.host == 'bsky.app' && uri.path.start_with?('/profile/')

    # Extract components from the URL
    path_parts = uri.path.split('/')
    did_or_handle = path_parts[2] # The part after /profile/
    post_id = path_parts[4]       # The part after /post/

    # Ensure we have a valid DID/handle and  post ID
    return if did_or_handle.blank? || post_id.blank?

    # If the profile path contains a DID, construct the at-uri directly
    at_uri = if did_or_handle.start_with?('did:plc:')
      "at://#{did_or_handle}/app.bsky.feed.post/#{post_id}"
    else
      # Resolve the handle to a DID
      did = resolve_handle(did_or_handle)
      return if did.blank?

      "at://#{did}/app.bsky.feed.post/#{post_id}"
    end

    $redis.set(cache_key, at_uri)
    at_uri
  end

  # Resolves a handle to its DID using the Bluesky API.
  #
  # @param handle [String] the handle to resolve.
  # @return [String, nil] the DID if resolved successfully, or nil if the handle cannot be resolved.
  def self.resolve_handle(handle)
    cache_key = "bluesky:dids:#{handle.parameterize}"
    did = $redis.get(cache_key)

    return did if did.present?

    response = HTTParty.get("#{BASE_URL}/xrpc/com.atproto.identity.resolveHandle", query: { "handle" => handle })

    return if response.code == 400
    did = JSON.parse(response.body)["did"]
    $redis.setex(cache_key, 1.day, did)
    did
  end
end
