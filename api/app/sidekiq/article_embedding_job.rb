# Keeps an article's Voyage embedding in sync with Contentful, off the webhook request path.
# Enqueued by the Contentful webhook (publish → "embed", unpublish/delete → "delete") and by the
# embeddings:backfill rake task. Arguments are plain strings and both operations are idempotent
# (embed overwrites, delete is a no-op on a missing key), so the retries below are safe. The stored
# value is a JSON `{ version:, vector: }` keyed by Contentful id; RelatedArticles reads it at request
# time so the related-articles endpoint never has to call Voyage itself.
class ArticleEmbeddingJob
  include Sidekiq::Job
  include MarkdownHelper # markdown_to_html, to strip the body down to plain prose before embedding

  sidekiq_options retry: 5

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

    # The article's real content as plain prose: title + intro + body (body is blank for a Short,
    # leaving intro). Intro/body are Markdown, so strip them to plain text — embed the words an
    # author wrote, not Markdown/HTML syntax.
    text = [article.title, plain_text(article.intro), plain_text(article.body)].reject(&:blank?).join("\n\n")
    vector = Embeddings.new.embed(text)
    # Leave any existing vector in place if the embed failed, rather than storing a blank one.
    return if vector.blank?

    payload = { version: article.sys&.published_version, vector: vector }
    $redis.set(self.class.redis_key(entry_id), payload.to_json)
  end

  # Strips a Markdown string to plain text (tags removed, entities decoded) — ported from the
  # static site's `sanitize` helper. Renders to HTML first so Markdown syntax (links, emphasis,
  # lists) becomes words rather than literal markup.
  def plain_text(markdown)
    return if markdown.blank?
    html = markdown_to_html(markdown)
    return if html.blank?
    HTMLEntities.new.decode(Sanitize.fragment(html).strip)
  end
end
