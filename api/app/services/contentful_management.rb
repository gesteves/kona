require "httparty"

# The Contentful Management API: the write side of Contentful.
#
# `ContentfulClient` reads content with the GraphQL delivery API, and this class writes it. The two
# use different hosts and different tokens, thus they are separate classes.
#
# The media uploader of the admin is the one caller today. It makes a published image asset in four
# steps, because the API gives no single call for that: an upload of the bytes, a create of the
# asset, a process of the file, and a publish.
#
# ⚠️ Each method RAISES on a result that is not a success. The caller is a Sidekiq job, thus a
# failure must do the work again and must not give a smaller result.
class ContentfulManagement < ApplicationService
  # The bytes go to a different host from the JSON.
  UPLOAD_API_URL = "https://upload.contentful.com/spaces".freeze
  MANAGEMENT_API_URL = "https://api.contentful.com/spaces".freeze

  CONTENT_TYPE = "application/vnd.contentful.management.v1+json".freeze

  # The default locale of the space. Each field of an asset is a map of locale to value.
  LOCALE = "en-US".freeze

  # The upload of the bytes runs in a REQUEST, inside the 20-second rack-timeout. Thus it must fail
  # before that timeout does, or the owner gets a 500 in place of a message.
  UPLOAD_TIMEOUT_SECONDS = 15

  # The processing of a file is asynchronous. These two run in a job and not in a request.
  POLL_INTERVAL = 2
  POLL_TIMEOUT = 300

  # @return [Boolean] True when this app can write to Contentful.
  def self.configured?
    ENV["CONTENTFUL_SPACE"].present? && ENV["CONTENTFUL_MANAGEMENT_TOKEN"].present?
  end

  # @return [String] The environment of the space. The default is the one that each space has.
  def environment
    ENV["CONTENTFUL_ENVIRONMENT"].presence || "master"
  end

  # Sends the bytes of one file to Contentful, and gets an Upload that an asset can point at.
  #
  # ⚠️ It reads the file from the DISK as a stream, and never with `File.read`. Puma already wrote
  # the body of the request to a temporary file, and a camera JPEG is 20MB to 38MB. Three Puma
  # threads with that file in the Ruby heap is the shape of the OOM kill of the first R2 backfill.
  #
  # ⚠️ An Upload of Contentful is retained for 24 hours. `StagedUpload::TTL` is below that number,
  # thus a stale id fails on our side with a message.
  #
  # @param path [String] The upload, on the disk.
  # @return [String] The id of the Upload.
  # @raise [ApplicationService::HttpError] For a result that is not a success.
  def create_upload(path)
    file = File.open(path, "rb")
    body = post_json!(
      "#{UPLOAD_API_URL}/#{space}/uploads",
      headers: token_header.merge(
        "Content-Type" => "application/octet-stream",
        # ⚠️ Net::HTTP raises for a body stream with no length and no chunked encoding.
        "Content-Length" => File.size(path).to_s
      ),
      body_stream: file,
      timeout: UPLOAD_TIMEOUT_SECONDS
    )
    body&.dig(:sys, :id)
  ensure
    file&.close
  end

  # Makes a draft asset that points at an Upload.
  # @param title [String] `fields.title`.
  # @param description [String] `fields.description`. This is the alt text that `web/` renders.
  # @param file_name [String] The name that Contentful puts in the URL of the asset.
  # @param content_type [String] The media type of the file.
  # @param upload_id [String] From #create_upload.
  # @return [Hash] `{ id:, version: }` of the new asset.
  # @raise [ApplicationService::HttpError]
  def create_asset(title:, description:, file_name:, content_type:, upload_id:)
    body = post_json!(
      assets_url,
      headers: json_headers,
      body: {
        fields: {
          title: { LOCALE => title.to_s },
          description: { LOCALE => description.to_s },
          file: {
            LOCALE => {
              contentType: content_type.to_s,
              fileName: file_name.to_s,
              uploadFrom: { sys: { type: "Link", linkType: "Upload", id: upload_id.to_s } }
            }
          }
        }
      }.to_json
    )
    { id: body.dig(:sys, :id), version: body.dig(:sys, :version) }
  end

  # Starts the processing of the file of an asset. Contentful gives the asset its CDN URL and its
  # dimensions here, and an asset with no processing cannot be published.
  # @param asset_id [String]
  # @param version [Integer] The current `sys.version` of the asset.
  # @return [void]
  # @raise [ApplicationService::HttpError]
  def process_asset(asset_id, version)
    put_json!(
      "#{assets_url}/#{asset_id}/files/#{LOCALE}/process",
      headers: json_headers.merge(version_header(version))
    )
    nil
  end

  # @param asset_id [String]
  # @return [Hash] The asset, with symbol keys.
  # @raise [ApplicationService::HttpError]
  def asset(asset_id)
    get_json!("#{assets_url}/#{asset_id}", headers: token_header)
  end

  # Processes the file of an asset, if that did not happen already, and waits for the end.
  #
  # ⚠️ It reads the asset first, on purpose. This is what makes the caller safe to run again: a
  # retry after a failed publish finds a file that has its URL and asks for no second processing,
  # and a retry after a failed process asks for it again.
  #
  # @param asset_id [String]
  # @return [Integer] The `sys.version` of the asset after the processing.
  # @raise [ApplicationService::HttpError]
  # @raise [RuntimeError] When the processing does not end inside POLL_TIMEOUT.
  def ensure_processed(asset_id)
    current = asset(asset_id)
    return current.dig(:sys, :version) if file_url(current).present?

    process_asset(asset_id, current.dig(:sys, :version))
    wait_for_processing(asset_id)
  end

  # Waits until the processing of a file ends.
  #
  # The process call answers at once and does the work later, thus the only signal is the `url` of
  # the file, which is absent until Contentful has it.
  #
  # @param asset_id [String]
  # @return [Integer] The `sys.version` of the asset after the processing.
  # @raise [ApplicationService::HttpError]
  # @raise [RuntimeError] When the processing does not end inside POLL_TIMEOUT.
  def wait_for_processing(asset_id)
    deadline = Time.now + POLL_TIMEOUT

    loop do
      sleep POLL_INTERVAL
      current = asset(asset_id)
      return current.dig(:sys, :version) if file_url(current).present?
      raise "ContentfulManagement: asset #{asset_id} did not finish processing in #{POLL_TIMEOUT}s" if Time.now >= deadline
    end
  end

  # Publishes an asset.
  # @param asset_id [String]
  # @param version [Integer] The current `sys.version` of the asset.
  # @return [Hash] `{ id:, version: }` of the published asset.
  # @raise [ApplicationService::HttpError]
  def publish_asset(asset_id, version)
    body = put_json!(
      "#{assets_url}/#{asset_id}/published",
      headers: json_headers.merge(version_header(version))
    )
    { id: body.dig(:sys, :id), version: body.dig(:sys, :version) }
  end

  private

  # @param asset [Hash] An asset from #asset.
  # @return [String, nil] The CDN URL of its file, which is absent until the processing ends.
  def file_url(asset)
    asset.dig(:fields, :file, LOCALE.to_sym, :url)
  end

  def space
    ENV["CONTENTFUL_SPACE"]
  end

  def assets_url
    "#{MANAGEMENT_API_URL}/#{space}/environments/#{environment}/assets"
  end

  def token_header
    { "Authorization" => "Bearer #{ENV['CONTENTFUL_MANAGEMENT_TOKEN']}" }
  end

  def json_headers
    token_header.merge("Content-Type" => CONTENT_TYPE)
  end

  # ⚠️ Contentful refuses a write whose version is not the current one. That is what stops two
  # writers from replacing the work of each other with no message.
  def version_header(version)
    { "X-Contentful-Version" => version.to_i.to_s }
  end
end
