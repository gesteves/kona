require 'erb'

module ShareHelpers
  # Generates a mailto URL for sharing an article via email.
  # @param article [Article] The article to be shared.
  # @return [String] The mailto URL.
  def mail_share_url(article)
    subject = ERB::Util.url_encode(og_title(article))
    body = ERB::Util.url_encode(full_url(article.path, { ref: 'Email' }))
    "mailto:?subject=#{subject}&body=#{body}"
  end

  # Generates an SMS URL for sharing an article via text message or iMessage.
  # @param article [Article] The article to be shared.
  # @return [String] The SMS URL.
  def sms_share_url(article)
    title = og_title(article)
    url = full_url(article.path, { ref: 'Text Message' })
    text = "#{title} #{url}"
    body = ERB::Util.url_encode(text)
    "sms:?&body=#{body}"
  end

  # Generates a URL for sharing an article on Facebook.
  # @param article [Article] The article to be shared.
  # @return [String] The Facebook share URL.
  def facebook_share_url(article)
    url = ERB::Util.url_encode(full_url(article.path, { ref: 'Facebook' }))
    "https://www.facebook.com/sharer/sharer.php?u=#{url}"
  end

  # Generates a URL for sharing an article on Reddit.
  # @param article [Article] The article to be shared.
  # @return [String] The Reddit share URL.
  def reddit_share_url(article)
    title = ERB::Util.url_encode(og_title(article))
    url = ERB::Util.url_encode(full_url(article.path, { ref: 'Reddit' }))
    "https://reddit.com/submit?title=#{title}&url=#{url}"
  end

  # Generates a URL for sharing an article on Threads.
  # @param article [Article] The article to be shared.
  # @return [String] The Threads share URL.
  def threads_share_url(article)
    title = og_title(article)
    url = full_url(article.path, { ref: 'Threads' })
    text = "#{title} #{url}"
    encoded_text = ERB::Util.url_encode(text)
    "https://www.threads.net/intent/post?text=#{encoded_text}"
  end

end
