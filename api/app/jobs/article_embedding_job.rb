# Keeps the Voyage embedding of an article the same as the content in Contentful. It runs outside
# the webhook request. You can do each operation more than one time: embed replaces the value, and
# delete does nothing for a key that is absent. Thus the retries from the parent class are safe. The
# stored value is a JSON `{ version:, vector: }` with the Contentful id as its key, and
# RelatedArticles reads it at request time.
class ArticleEmbeddingJob < ApplicationJob
  include MarkdownHelper # markdown_to_plain_text, to strip the body down to plain prose before embedding

  REDIS_KEY_PREFIX = "embeddings:article:".freeze

  # @param id [String] The Contentful entry id.
  # @return [String] The Redis key that holds the embedding of that article.
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

    # The code changes this into plain text, thus the embedding uses the words of the author and not
    # the Markdown syntax.
    text = [ article.title, markdown_to_plain_text(article.intro), markdown_to_plain_text(article.body) ].reject(&:blank?).join("\n\n")
    vector = Embeddings.new.embed(text)
    # This keeps a vector that exists and does not store a blank one.
    return if vector.blank?

    payload = { version: article.sys&.published_version, vector: vector }
    $redis.set(self.class.redis_key(entry_id), payload.to_json)
  end
end
