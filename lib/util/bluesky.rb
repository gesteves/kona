require 'httparty'
require 'active_support/all'
require 'nokogiri'
require 'redcarpet'
require 'htmlentities'

class Bluesky
  BASE_URL = "https://bsky.social".freeze

  # Initializes a new instance of the Bluesky class.
  #
  # @param email [String] the email for the Bluesky account.
  # @param password [String] the single-app password for the Bluesky account.
  def initialize(email:, password:)
    session = create_session(email: email, password: password)
    @did = session["did"]
    @access_token = session["accessJwt"]
  end

  # Posts an article to Bluesky, creating a new post with optional text and embed data from a URL.
  #
  # @param url [String] The URL to embed in the post.
  # @param text [String, nil] Optional text to include in the post.
  # @return [String, nil] The public Bluesky post URL, or nil if the post creation fails.
  def post_article(url:, text: nil)
    record_data = construct_record(url, text)
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
  # @param post_url [String] The public Bluesky post URL.
  # @return [String, nil] The at-uri for the post, or nil if the URL is invalid or cannot be resolved.
  def self.post_url_to_at_uri(post_url)
    return if post_url.blank?

    cache_key = "bluesky:posts:at-uri:#{post_url.parameterize}"
    at_uri = $redis.get(cache_key)

    return at_uri if at_uri.present?

    uri = URI.parse(post_url)
    return unless uri.host == 'bsky.app' && uri.path.start_with?('/profile/')

    path_parts = uri.path.split('/')
    did_or_handle = path_parts[2]
    post_id = path_parts[4]

    return if did_or_handle.blank? || post_id.blank?

    at_uri = if did_or_handle.start_with?('did:plc:')
               "at://#{did_or_handle}/app.bsky.feed.post/#{post_id}"
             else
               did = resolve_handle(did_or_handle)
               return if did.blank?

               "at://#{did}/app.bsky.feed.post/#{post_id}"
             end

    $redis.set(cache_key, at_uri)
    at_uri
  end

  # Resolves a handle to its DID using the Bluesky API.
  #
  # @param handle [String] The handle to resolve.
  # @return [String, nil] The DID if resolved successfully, or nil if the handle cannot be resolved.
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
  # @param email [String] The email for the Bluesky account.
  # @param password [String] The single-app password for the Bluesky account.
  # @return [Hash] The session data containing the DID and access token.
  # @raise [RuntimeError] If the session creation request fails.
  def create_session(email:, password:)
    body = { identifier: email, password: password }
    response = HTTParty.post("#{BASE_URL}/xrpc/com.atproto.server.createSession", body: body.to_json, headers: { "Content-Type" => "application/json" })

    if response.success?
      JSON.parse(response.body)
    else
      raise "Unable to create a new session."
    end
  end

  # Uploads a photo to the Bluesky API and returns the response blob.
  #
  # @param url [String] The URL of the photo to upload.
  # @return [Hash] The response data for the uploaded blob.
  # @raise [RuntimeError] If the upload fails.
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
  #
  # @param record [Hash] The record data to send to the API.
  # @return [Hash] The response data from the API.
  # @raise [RuntimeError] If the request fails.
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

  # Constructs a record for posting an article.
  #
  # @param url [String] The URL of the article.
  # @param text [String] The text content of the post.
  # @return [Hash, nil] The record data, or nil if the required metadata is missing.
  def construct_record(url, text)
    html = Nokogiri::HTML(HTTParty.get(url).body)

    title = html.css("meta[property='og:title']")&.first&.[]("content")
    description = html.css("meta[property='og:description']")&.first&.[]("content")
    image_url = html.css("meta[property='og:image']")&.first&.[]("content")
    published_time = html.css("meta[property='article:published_time']")&.first&.[]("content")

    created_at = begin
                   parsed_time = DateTime.parse(published_time) rescue nil
                   parsed_time && parsed_time < 1.day.ago ? parsed_time : Time.now
                 rescue
                   Time.now
                 end

    return if title.blank? && description.blank?

    embed = {
      "$type" => "app.bsky.embed.external",
      "external" => {
        "uri" => url,
        "title" => title.presence,
        "description" => description.presence
      }.compact
    }

    if image_url.present?
      blob = upload_photo(image_url)["blob"]
      embed["external"]["thumb"] = blob if blob.present?
    end

    {
      text: smartypants(text),
      langs: ["en-US"],
      createdAt: created_at.iso8601,
      embed: embed
    }
  rescue StandardError => e
    puts "Error constructing record: #{e.message}"
    nil
  end

  # Applies SmartyPants rendering to the provided text for typographic improvements.
  #
  # @param text [String] The text to process.
  # @return [String] The processed text, or an empty string if the input is blank.
  def smartypants(text)
    return "" if text.blank?
    HTMLEntities.new.decode(Redcarpet::Render::SmartyPants.render(text))
  end
end
