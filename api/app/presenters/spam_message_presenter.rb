require "time"

# Presents one quarantined contact-form submission as a card on the Contact page.
#
# Surfaces the same fields the notification email carries, so reviewing a message here tells the
# owner exactly what they'd have seen in their inbox.
#
# ⚠️ Every string here is unfiltered attacker input. This class only ever formats and truncates —
# it never marks anything `html_safe`, and the view must render these with plain `<%= %>`.
class SpamMessagePresenter
  # Where the body is cut before the "Show full message" disclosure takes over. Long enough to
  # judge a message by, short enough that a queue of them stays scannable.
  PREVIEW_LIMIT = 280

  attr_reader :id, :name, :email, :message, :not_spam_path, :delete_path

  # @param payload [Hash] One SpamQuarantine entry: "id", "name", "email", "message", "context",
  #   and "received_at".
  # @param not_spam_path [String] Where the "Not spam" form posts.
  # @param delete_path [String] Where the "Delete forever" form posts.
  def initialize(payload:, not_spam_path:, delete_path:)
    @id = payload["id"].to_s
    @name = payload["name"].to_s
    @email = payload["email"].to_s
    @message = payload["message"].to_s
    @context = payload["context"] || {}
    @received_at = payload["received_at"].to_s
    @not_spam_path = not_spam_path
    @delete_path = delete_path
  end

  # @return [String, nil] City, region, and country joined, or nil when the proxy forwarded none.
  def location
    joined = [ @context["city"], @context["region"], @context["country"] ].reject(&:blank?).join(", ")
    joined.presence
  end

  # @return [String, nil] The visitor IP the web proxy forwarded.
  def ip
    @context["ip"].presence
  end

  # @return [String, nil] The visitor User-Agent the web proxy forwarded.
  def user_agent
    @context["user_agent"].presence
  end

  # @return [String] The ISO 8601 submission time, for <wa-relative-time> and the details line.
  def received_at
    @received_at
  end

  # @return [Boolean] Whether the body is long enough to need the disclosure.
  def truncated?
    @message.length > PREVIEW_LIMIT
  end

  # @return [String] The body, cut at a word boundary when it's over the limit.
  def preview
    return @message unless truncated?

    @message.truncate(PREVIEW_LIMIT, separator: " ")
  end

  # @return [String] The DOM id of this card's delete-confirmation dialog.
  def dialog_id
    "spam-delete-#{@id}"
  end
end
