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
  KEY_PREFIX = "contentful:staged:".freeze

  # ⚠️ An Upload of Contentful is retained for 24 hours. This is below that number, thus a stale
  # tile fails here, with a message of ours, and never at Contentful with one of theirs.
  TTL = 12.hours

  # The shape of an id, which `#store` makes.
  ID_PATTERN = /\A\h{32}\z/

  # @param value [Object]
  # @return [Boolean] True when the value has the shape of an id.
  def self.id?(value)
    value.is_a?(String) && value.match?(ID_PATTERN)
  end

  # Keeps one picked file.
  # @param thumbnail [String] The small JPEG of the tile, which Claude also reads.
  # @param upload_id [String] The Upload of Contentful that holds the original bytes.
  # @param file_name [String] The name of the file that the owner picked.
  # @param content_type [String] Its media type.
  # @param width [Integer] The width of the thumbnail.
  # @param height [Integer] The height of the thumbnail.
  # @return [String] The id.
  def store(thumbnail:, upload_id:, file_name:, content_type:, width:, height:)
    id = SecureRandom.hex(16)
    key = key_for(id)

    # ⚠️ Both in one transaction, thus no key can exist with no TTL.
    $redis.multi do |tx|
      tx.hset(key, "thumbnail", thumbnail, "upload_id", upload_id.to_s, "file_name", file_name.to_s,
              "content_type", content_type.to_s, "width", width.to_i, "height", height.to_i)
      tx.expire(key, TTL.to_i)
    end
    id
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

  # @param id [String]
  # @return [Boolean]
  def exists?(id)
    self.class.id?(id) && $redis.exists?(key_for(id))
  end

  # @param ids [Array<String>]
  # @return [void]
  def discard(ids)
    keys = Array(ids).select { |id| self.class.id?(id) }.map { |id| key_for(id) }
    $redis.del(*keys) if keys.any?
  end

  private

  def key_for(id)
    "#{KEY_PREFIX}#{id}"
  end
end
