require "time"

# Presents one uploaded GPX track, both as a card on the Maps index and as the subject of the
# render-settings page.
#
# Paths are passed in rather than built here, matching ConnectedAppPresenter — the view stays
# free of route helpers and the presenter free of Rails' URL machinery.
class MapTrackPresenter
  attr_reader :id, :title, :activity_type, :error,
    :show_path, :preview_path, :download_path, :delete_path

  # @param record [Hash] One TrackLibrary record.
  # @param show_path [String] The settings page for this track.
  # @param preview_path [String] The proxied preview image.
  # @param download_path [String] The proxied full-size download.
  # @param delete_path [String] Where the delete form posts.
  def initialize(record:, show_path:, preview_path:, download_path:, delete_path:)
    @id = record["id"].to_s
    @title = record["title"].to_s
    @activity_type = record["activity_type"].to_s
    @status = record["status"].to_s
    @error = record["error"].presence
    @uploaded_at = record["uploaded_at"].to_s
    @settings = record["settings"] || {}
    @show_path = show_path
    @preview_path = preview_path
    @download_path = download_path
    @delete_path = delete_path
  end

  # @return [String] "processing", "ready", or "failed".
  def status
    TrackLibrary::STATUSES.include?(@status) ? @status : "processing"
  end

  # @return [Boolean] Whether Mapbox is still publishing this track's tileset.
  def processing? = status == "processing"

  # @return [Boolean] Whether this track can be rendered.
  def ready? = status == "ready"

  # @return [Boolean] Whether publishing gave up.
  def failed? = status == "failed"

  # @return [String] The badge label for the current status.
  def status_label
    { "processing" => "Processing", "ready" => "Ready", "failed" => "Failed" }.fetch(status)
  end

  # @return [String] The Web Awesome badge variant for the current status.
  def status_variant
    { "processing" => "neutral", "ready" => "success", "failed" => "danger" }.fetch(status)
  end

  # @return [String] The ISO 8601 upload time, for <wa-relative-time>.
  def uploaded_at = @uploaded_at

  # @return [String] The sport, e.g. "Road Biking".
  def summary = @activity_type

  # The render settings, with any missing key filled in from the defaults — a record written before
  # a new setting existed still has to render.
  #
  # A "custom" style that is in fact one of Mapbox's own belongs in the dropdown, not in the
  # override box. That keeps the box empty unless it's genuinely overriding something, and it's
  # how records written before the dropdown existed — when every style lived in `style_url` —
  # migrate themselves on first read.
  # @return [Hash]
  def settings
    merged = StaticMap.defaults_for(nil).merge(@settings)
    return merged unless StaticMap::STYLE_PRESETS.key?(merged["style_url"])

    merged.merge("style_preset" => merged["style_url"], "style_url" => "")
  end

  # @param key [String] A setting name.
  # @return [Object] Its current value.
  def setting(key) = settings[key]

  # @return [String] The DOM id of this track's delete-confirmation dialog.
  def dialog_id = "map-delete-#{@id}"
end
