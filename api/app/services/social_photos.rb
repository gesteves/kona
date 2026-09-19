# The photos of a draft on the Social media page, between the upload and the post.
#
# Each photo goes into its own Redis key, as the coordinates of a course-map upload do. `app` and
# `worker` are different fly machines, thus a temporary file of the request is not there for the
# job, and a photo is as much as 2MB, which is too large for a Sidekiq argument.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call.
#
# ⚠️ One key for each photo, with a TTL, on purpose. `JsonHashStore` keeps its records in one hash
# with no TTL, and a photo must go away by itself: a draft that the owner never posts must not
# keep 20MB for all time. Thus these keys are in group 2 of "What Redis holds", and `volatile-lru`
# can remove one at the memory cap. The job then fails that post permanently and reports it.
class SocialPhotos
  KEY_PREFIX = "social:photo:".freeze

  # How long a photo stays before the owner posts the draft. `Admin::SocialController` makes it
  # longer at the submit, thus a scheduled post keeps its photos through the retry window.
  DRAFT_TTL = 24.hours

  # The shape of an id, which `#store` makes.
  ID_PATTERN = /\A\h{32}\z/

  # @param value [Object]
  # @return [Boolean] True when the value has the shape of an id.
  def self.id?(value)
    value.is_a?(String) && value.match?(ID_PATTERN)
  end

  # Keeps one prepared photo.
  # @param image [String] The JPEG bytes.
  # @param width [Integer]
  # @param height [Integer]
  # @return [String] The id.
  def store(image:, width:, height:)
    id = SecureRandom.hex(16)
    key = key_for(id)

    # ⚠️ Both in one transaction, thus no key can exist with no TTL.
    $redis.multi do |tx|
      tx.hset(key, "image", image, "width", width.to_i, "height", height.to_i)
      tx.expire(key, DRAFT_TTL.to_i)
    end
    id
  end

  # @param id [String]
  # @return [Hash, nil] `{ image:, width:, height: }`, or nil when the photo is absent.
  def fetch(id)
    return nil unless self.class.id?(id)

    image, width, height = $redis.hmget(key_for(id), "image", "width", "height")
    return nil if image.blank?

    # ⚠️ redis-rb tags each string UTF-8. A JPEG with that tag is an invalid string, and a later
    # step that reads it as text raises.
    { image: image.b, width: width.to_i, height: height.to_i }
  end

  # @param id [String]
  # @return [Boolean]
  def exists?(id)
    self.class.id?(id) && $redis.exists?(key_for(id))
  end

  # Gives each photo a new TTL, for a post that waits.
  # @param ids [Array<String>]
  # @param seconds [Integer]
  # @return [void]
  def keep(ids, seconds)
    ids.select { |id| self.class.id?(id) }.each { |id| $redis.expire(key_for(id), seconds.to_i) }
  end

  # @param ids [Array<String>]
  # @return [void]
  def discard(ids)
    keys = ids.select { |id| self.class.id?(id) }.map { |id| key_for(id) }
    $redis.del(*keys) if keys.any?
  end

  private

  def key_for(id)
    "#{KEY_PREFIX}#{id}"
  end
end
