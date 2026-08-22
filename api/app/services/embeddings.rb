# Changes text into a vector with the embeddings endpoint of Voyage AI, to find the articles with
# the nearest meaning. It is general, on purpose: ArticleEmbeddingJob makes the text of an
# article.
class Embeddings < ApplicationService
  VOYAGE_API_URL = "https://api.voyageai.com/v1/embeddings".freeze
  # ⚠️ After a change to the model, run embeddings:backfill again. Thus one model gives the order of
  # each article.
  MODEL = "voyage-4-large".freeze

  def initialize
    @api_key = ENV["VOYAGE_API_KEY"]
  end

  # Makes the vector of one document.
  # @param text [String] The text.
  # @return [Array<Float>, nil] Its vector, or nil when there is no configuration, when the text is
  #   blank, and when the call fails. Without a vector, the code removes the article from the list of
  #   related articles.
  def embed(text)
    return if @api_key.blank? || text.blank?

    # post_json! raises, thus with_retries covers a 4xx response and a 5xx response from Voyage, and
    # also a network error.
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
