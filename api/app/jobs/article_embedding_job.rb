# Keeps an article's Voyage embedding in sync with Contentful, off the webhook request path.
# Both operations are idempotent — embed overwrites, delete no-ops on a missing key — so the
# inherited retries are safe. The stored value is a JSON `{ version:, vector: }` keyed by
# Contentful id, which RelatedArticles reads at request time.
class ArticleEmbeddingJob < ApplicationJob
  include MarkdownHelper # markdown_to_plain_text, to strip the body down to plain prose before embedding

  REDIS_KEY_PREFIX = "embeddings:article:".freeze

  # @param id [String] The Contentful entry id.
  # @return [String] The Redis key holding that article's embedding.
  def self.redis_key(id)
    "#{REDIS_KEY_PREFIX}#{id}"
  end

  # @param operation [String] "embed" or "delete".
  # @param entry_id [String] The Contentful entry id.
  def perform(operation, entry_id)
    return if entry_id.blank?

    case operation
    when "embed"  then embed(entry_id)
    when "delete" then $redis.del(self.class.redis_key(entry_id))
    else
      Rails.logger.warn("ArticleEmbeddingJob: unknown operation #{operation.inspect}; ignoring")
    end
  end

  private

  def embed(entry_id)
    article = Articles.new.find_for_embedding(entry_id)
    return if article.blank?

    # Stripped to plain text, so the embedding covers the words an author wrote rather than
    # Markdown syntax.
    text = [ article.title, markdown_to_plain_text(article.intro), markdown_to_plain_text(article.body) ].reject(&:blank?).join("\n\n")
    vector = Embeddings.new.embed(text)
    # Leaves any existing vector in place rather than storing a blank one.
    return if vector.blank?

    payload = { version: article.sys&.published_version, vector: vector }
    $redis.set(self.class.redis_key(entry_id), payload.to_json)
  end
end
