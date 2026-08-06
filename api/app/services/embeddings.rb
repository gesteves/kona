# Turns text into a vector via Voyage AI's embeddings endpoint, for finding semantically related
# articles. Generic on purpose — the article-specific text assembly lives in
# ArticleEmbeddingJob.
class Embeddings < ApplicationService
  VOYAGE_API_URL = "https://api.voyageai.com/v1/embeddings".freeze
  # ⚠️ Switching models means re-running embeddings:backfill, so the whole corpus is ranked on
  # one model.
  MODEL = "voyage-4-large".freeze

  def initialize
    @api_key = ENV["VOYAGE_API_KEY"]
  end

  # Embeds a single document.
  # @param text [String] The text to embed.
  # @return [Array<Float>, nil] Its vector, or nil when unconfigured, blank, or the call fails —
  #   a missing vector just drops the article from the related-articles ranking.
  def embed(text)
    return if @api_key.blank? || text.blank?

    # post_json! raises, so with_retries covers Voyage's 4xx/5xx responses as well as
    # network-level exceptions.
    with_retries do
      data = post_json!(
        VOYAGE_API_URL,
        headers: { "Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json" },
        body: {
          input: text,
          model: MODEL,
          input_type: "document",
          truncation: true
        }.to_json
      )
      data&.dig(:data, 0, :embedding)
    end
  end
end
