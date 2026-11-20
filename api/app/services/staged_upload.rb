# One file that the owner picked on the media uploader, between the pick and the submit.
#
# The bytes are NOT here: they went to Contentful at the pick, and this record keeps only the id of
# that Upload. The thumbnail is here, because the tile shows it and Claude reads it.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call.
#
# ⚠️ One key for each file, with a TTL, as `SocialPhotos` has. A page that the owner never submits
# must not keep its records for all time. Thus these keys are in group 2 of "What Redis holds", and
# `volatile-lru` can remove one at the memory cap. The job then fails that file and reports it.
class StagedUpload
  include ExpiringKeyStore

  KEY_PREFIX = "contentful:staged:".freeze

  # ⚠️ An Upload of Contentful is retained for 24 hours. This is below that number, thus a stale
  # tile fails here, with a message of ours, and never at Contentful with one of theirs.
  TTL = 12.hours

  # Keeps one picked file.
  # @param thumbnail [String] The small JPEG of the tile, which Claude also reads.
  # @param upload_id [String] The Upload of Contentful that holds the original bytes.
  # @param file_name [String] The name of the file that the owner picked.
  # @param content_type [String] Its media type.
  # @param width [Integer] The width of the thumbnail.
  # @param height [Integer] The height of the thumbnail.
  # @return [String] The id.
  def store(thumbnail:, upload_id:, file_name:, content_type:, width:, height:)
    write_new(TTL, "thumbnail" => thumbnail, "upload_id" => upload_id.to_s, "file_name" => file_name.to_s,
                   "content_type" => content_type.to_s, "width" => width.to_i, "height" => height.to_i)
  end

  # @param id [String]
  # @return [Hash, nil] The record with symbol keys, or nil when the file is absent.
  def fetch(id)
    return nil unless self.class.id?(id)

    thumbnail, upload_id, file_name, content_type, width, height =
      $redis.hmget(key_for(id), "thumbnail", "upload_id", "file_name", "content_type", "width", "height")
    return nil if thumbnail.blank?

    # ⚠️ redis-rb tags each string UTF-8. A JPEG with that tag is an invalid string, and a later
    # step that reads it as text raises.
    { thumbnail: thumbnail.b, upload_id: upload_id.to_s, file_name: file_name.to_s,
      content_type: content_type.to_s, width: width.to_i, height: height.to_i }
  end
end
