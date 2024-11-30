require 'httparty'
require 'active_support/all'
require 'nokogiri'

class Bluesky
  BASE_URL = "https://bsky.social".freeze

  # Initializes a new instance of the Bluesky class.
  #
  # @param base_url [String] the base URL of the Bluesky API.
  # @param email [String] the email for the Bluesky account.
  # @param password [String] the single-app password for the Bluesky account.
  def initialize(email:, password:)
    session = create_session(email: email, password: password)
    @did = session["did"]
    @access_token = session["accessJwt"]
  end

  def post_article(url)
    # Construct the embed object, if provided
    record_data = construct_record(url)
    return if record_data.blank?

    record = {
      repo: @did,
      collection: "app.bsky.feed.post",
      record: record_data
    }

    response = create_record(record)
    uri = response["uri"]

    if uri.start_with?("at://")
      components = uri.split("/")
      handle = components[2]
      post_id = components[-1]
      "https://bsky.app/profile/#{handle}/post/#{post_id}"
    else
      uri
    end
  end


  # Converts a Bluesky post URL into an at-uri.
  #
  # @param post_url [String] the public Bluesky post URL.
  # @return [String] the at-uri for the post.
  # @raise [ArgumentError] if the post URL is invalid.
  def self.post_url_to_at_uri(post_url)
    return if post_url.blank?

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
    return if handle.blank?

    cache_key = "bluesky:dids:#{handle.parameterize}"
    did = $redis.get(cache_key)

    return did if did.present?

    response = HTTParty.get("#{BASE_URL}/xrpc/com.atproto.identity.resolveHandle", query: { "handle" => handle })

    return if response.code == 400
    did = JSON.parse(response.body)["did"]
    $redis.setex(cache_key, 1.day, did)
    did
  end

  private

  # Creates a new session with the Bluesky API and caches the DID and access token.
  #
  # @param email [String] the email for the Bluesky account.
  # @param password [String] the single-app password for the Bluesky account.
  # @return [Hash] the response from the session creation request.
  # @raise [RuntimeError] if the session creation request fails.
  def create_session(email:, password:)
    body = {
      identifier: email,
      password: password
    }

    response = HTTParty.post("#{BASE_URL}/xrpc/com.atproto.server.createSession", body: body.to_json, headers: { "Content-Type" => "application/json" })
    if response.success?
      JSON.parse(response.body)
    else
      raise "Unable to create a new session."
    end
  end

  # Uploads a photo to the Bluesky API and returns the response blob.
  #
  # @param url [String] the URL of the photo to upload.
  # @return [Hash] the parsed response body from the photo upload request.
  # @raise [RuntimeError] if the photo upload request fails.
  def upload_photo(url)
    image_data = HTTParty.get(url).body

    headers = {
      "Authorization" => "Bearer #{@access_token}",
      "Content-Type" => "image/jpeg"
    }

    response = HTTParty.post("#{BASE_URL}/xrpc/com.atproto.repo.uploadBlob", body: image_data, headers: headers)

    if response.success?
      JSON.parse(response.body)
    else
      raise "Failed to upload photo: #{response.body}"
    end
  end

  # Creates a record in the Bluesky API for the specified collection.
  # @param record [Hash] the record data to send to the API.
  # @return [Hash] the parsed response body if successful.
  # @raise [RuntimeError] if the post request fails.
  def create_record(record)
    headers = {
      "Authorization" => "Bearer #{@access_token}",
      "Content-Type" => "application/json"
    }

    response = HTTParty.post("#{BASE_URL}/xrpc/com.atproto.repo.createRecord",
                             body: record.to_json,
                             headers: headers)

    if response.success?
      JSON.parse(response.body)
    else
      raise "Failed to create #{record[:collection]} record: #{response.body}"
    end
  end

  def construct_record(url)
    # Open the URL and parse the HTML using Nokogiri
    html = Nokogiri::HTML(HTTParty.get(url).body)

    # Extract OpenGraph metadata
    title = html.css("meta[property='og:title']")&.first&.[]("content")
    description = html.css("meta[property='og:description']")&.first&.[]("content")
    image_url = html.css("meta[property='og:image']")&.first&.[]("content")
    published_time = html.css("meta[property='article:published_time']")&.first&.[]("content")

    # If published_time is missing or within the last day, use the current time.
    created_at = begin
      published_time = DateTime.parse(published_time)
      published_time < 1.day.ago ? published_time : Time.now
    rescue
      Time.now
    end

    # Return nil if title, description, and image are all missing
    return if title.blank? && description.blank? && image_url.blank?

    # Prepare the embed object
    embed = {
      "$type" => "app.bsky.embed.external",
      "external" => {
        "uri" => url,
        "title" => title.presence,
        "description" => description.presence
      }.compact
    }

    # Add the thumbnail blob if an image URL is present
    if image_url.present?
      blob = upload_photo(image_url)["blob"]
      embed["external"]["thumb"] = blob if blob.present?
    end

    # Construct and return the record object
    {
      text: "",
      langs: ["en-US"],
      createdAt: created_at.iso8601,
      embed: embed
    }
  rescue StandardError => e
    # Log the error and return nil to skip posting
    puts "Error constructing record: #{e.message}"
    nil
  end
end
