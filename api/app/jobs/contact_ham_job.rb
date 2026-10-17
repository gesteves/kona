# Tells Akismet that its mark on a message was incorrect, after the owner sends that message from
# the spam quarantine. Thus Akismet stops the mark on the same sender. It is a separate job, thus a
# failure of the report retries and never stops the delivery of the message.
class ContactHamJob < ContactJob
  # @param name [String] The name of the sender.
  # @param email [String] The email address of the sender.
  # @param message [String] The body of the message.
  # @param context [Hash] The sender data from the quarantine: "ip" and "user_agent" go to Akismet.
  def perform(name, email, message, context = {})
    context ||= {}

    Akismet.new.submit_ham(content: message, author: name, author_email: email,
      user_ip: context["ip"], user_agent: context["user_agent"])
    Rails.logger.info("Contact form: reported a false positive to Akismet")
  end
end
