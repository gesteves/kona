# Thin wrapper over Voyage AI's text-embeddings endpoint. Turns a chunk of text into a vector
# (a list of floats) used to find semantically-related articles. Generic on purpose: text in,
# vector out — the article-specific text assembly lives in ArticleEmbeddingJob. Uses the shared
# HTTParty + retry/error-handling plumbing from ApplicationService.
class Embeddings < ApplicationService
  VOYAGE_API_URL = "https://api.voyageai.com/v1/embeddings".freeze
  # voyage-4-large: the best general-purpose retrieval quality in the 4 series; 1024-dim default.
  # All 4-series embeddings are mutually compatible, but switching models means re-running
  # embeddings:backfill so the whole corpus is ranked on one model.
  MODEL = "voyage-4-large".freeze

  def initialize
    @api_key = ENV["VOYAGE_API_KEY"]
  end

  # Embeds a single document and returns its vector, or nil when the key is missing, the text is
  # blank, or the API call fails (callers degrade gracefully — a missing vector just drops the
  # article from related-article ranking).
  # @param text [String] The document text to embed.
  # @return [Array<Float>, nil]
  def embed(text)
    return if @api_key.blank? || text.blank?

    with_retries do
      data = post_json(
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
