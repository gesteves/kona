require "time"

# Presents one contact-form submission from the quarantine, as a card on the Contact page.
#
# It shows the same fields as the notification email. Thus a message here gives the owner the same
# data that their inbox would give.
#
# ⚠️ Each string here is input from an attacker, and no code removes anything from it. This class
# only formats a value and makes it shorter. It never marks a value `html_safe`, and the view must
# render each value with a plain `<%= %>`.
class SpamMessagePresenter
  # The point where the code cuts the body, and the "Show full message" control then gives the rest.
  # It is long enough to judge the message, and short enough to keep a list of messages easy to
  # read.
  PREVIEW_LIMIT = 280

  attr_reader :id, :name, :email, :message, :not_spam_path, :delete_path

  # @param payload [Hash] One SpamQuarantine entry: "id", "name", "email", "message", "context",
  #   and "received_at".
  # @param not_spam_path [String] The path that the "Not spam" form posts to.
  # @param delete_path [String] The path that the "Delete forever" form posts to.
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

  # @return [String, nil] The city, the region, and the country, joined, or nil if the proxy sent
  #   none of them.
  def location
    joined = [ @context["city"], @context["region"], @context["country"] ].reject(&:blank?).join(", ")
    joined.presence
  end

  # @return [String, nil] The visitor IP that the web proxy sent.
  def ip
    @context["ip"].presence
  end

  # @return [String, nil] The visitor User-Agent that the web proxy sent.
  def user_agent
    @context["user_agent"].presence
  end

  # @return [String] The submission time in ISO 8601, for <wa-relative-time> and the details line.
  def received_at
    @received_at
  end

  # @return [Boolean] True if the body is long enough to need the control.
  def truncated?
    @message.length > PREVIEW_LIMIT
  end

  # @return [String] The body. The code cuts it between two words when it is longer than the
  #   limit.
  def preview
    return @message unless truncated?

    @message.truncate(PREVIEW_LIMIT, separator: " ")
  end

  # @return [String] The DOM id of the delete-confirmation dialog of this card.
  def dialog_id
    "spam-delete-#{@id}"
  end
end
