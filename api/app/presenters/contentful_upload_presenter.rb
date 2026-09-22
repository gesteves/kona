# Presents one record of the media uploader, as a row of the recent-uploads list.
class ContentfulUploadPresenter
  attr_reader :id, :title, :file_name, :asset_id, :error, :uploaded_at

  # One tile of the form, before the owner submits it. The `<template>` of the page renders an
  # empty one, thus the tile markup is in the partial and in no other place.
  #
  # ⚠️ Each member has a blank default, and not nil: the partial writes each value into an
  # attribute of a form control.
  File = Data.define(:id, :title, :alt) do
    def initialize(id: "", title: "", alt: "")
      super(id: id.to_s, title: title.to_s, alt: alt.to_s)
    end
  end

  # @param record [Hash] One UploadLibrary record.
  def initialize(record)
    @id = record["id"].to_s
    @title = record["title"].to_s
    @file_name = record["file_name"].to_s
    @status = record["status"].to_s
    @asset_id = record["asset_id"].presence
    @error = record["error"].presence
    @uploaded_at = record["uploaded_at"].to_s
  end

  # @return [String] "processing", "published", or "failed".
  def status
    UploadLibrary::STATUSES.include?(@status) ? @status : "processing"
  end

  # @return [Boolean] True while the job still makes the asset.
  def processing? = status == "processing"

  # @return [Boolean] True when the asset is in Contentful and published.
  def published? = status == "published"

  # @return [Boolean] True when the publish stopped after the last attempt.
  def failed? = status == "failed"

  # @return [String] The label of the badge for the current status.
  def status_label
    I18n.t("admin.contentful_uploads.status.#{status}")
  end

  # @return [String] The Web Awesome badge variant for the current status. ⚠️ A variant is a
  #   component value and not a word: it stays here, beside #status_label, which left.
  def status_variant
    { "processing" => "neutral", "published" => "success", "failed" => "danger" }.fetch(status)
  end
end
