require "time"

# Presents one GPX track that a user uploaded, as a card on the Maps index and as the subject of
# the render-settings page.
#
# The caller gives each path, and this class does not make one. ConnectedAppPresenter does the same.
# Thus the view uses no route helper and this presenter uses no Rails URL code.
class MapTrackPresenter
  attr_reader :id, :title, :activity_type, :error,
    :show_path, :preview_path, :download_path, :delete_path

  # @param record [Hash] One TrackLibrary record.
  # @param show_path [String] The settings page of this track.
  # @param preview_path [String] The preview image, through the proxy.
  # @param download_path [String] The full-size download, through the proxy.
  # @param delete_path [String] The path that the delete form posts to.
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

  # @return [Boolean] True if Mapbox still publishes the tileset of this track.
  def processing? = status == "processing"

  # @return [Boolean] True if the code can render this track.
  def ready? = status == "ready"

  # @return [Boolean] True if the publish stopped after the last attempt.
  def failed? = status == "failed"

  # @return [String] The label of the badge for the current status.
  def status_label
    I18n.t("admin.course_maps.status.#{status}")
  end

  # @return [String] The Web Awesome badge variant for the current status.
  def status_variant
    { "processing" => "neutral", "ready" => "success", "failed" => "danger" }.fetch(status)
  end

  # @return [String] The upload time in ISO 8601, for <wa-relative-time>.
  def uploaded_at = @uploaded_at

  # @return [String] The sport, for example "Road Biking".
  def summary = @activity_type

  # The render settings. Each key that is absent gets its default value, because a record from
  # before a new setting must still render.
  #
  # A "custom" style that is in fact a Mapbox style belongs in the dropdown, and not in the override
  # box. Thus the box stays empty until it truly replaces a style. This is also how a record from
  # before the dropdown, when each style was in `style_url`, changes itself at the first read.
  # @return [Hash]
  def settings
    return @merged_settings if defined?(@merged_settings)

    merged = StaticMap.defaults_for(nil).merge(@settings)
    if StaticMap::STYLE_PRESETS.key?(merged["style_url"])
      merged = merged.merge("style_preset" => merged["style_url"], "style_url" => "")
    end
    @merged_settings = merged
  end

  # @param key [String] The name of a setting.
  # @return [Object] Its current value.
  def setting(key) = settings[key]

  # @return [String] The DOM id of the delete-confirmation dialog of this track.
  def dialog_id = "map-delete-#{@id}"
end
