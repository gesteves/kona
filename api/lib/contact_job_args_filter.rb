# A Bugsnag callback that removes the arguments of a contact-form job from its report. The Sidekiq
# integration of Bugsnag puts the full job in the `sidekiq` tab, and the arguments of these two jobs
# are the name, the email address, the message, and the IP of a sender. The `filter_parameters` of
# Rails match a hash key only, thus they do not reach a positional argument. Akismet fails closed,
# thus an Akismet outage would send that data on each retry.
#
# ⚠️ This replaces the `msg` of the tab with a copy. The tab holds the same Hash that Sidekiq uses
# for the retry, thus a change in place would remove the arguments of the job itself.
class ContactJobArgsFilter
  # The jobs whose arguments hold the data of a sender.
  JOB_CLASSES = %w[ContactMailJob ContactDeliveryJob].freeze

  # @param report [Bugsnag::Report] The report that Bugsnag is ready to send.
  # @return [Boolean] Always true: the report goes out, with no arguments.
  def self.call(report)
    tab = report.metadata[:sidekiq]
    msg = tab[:msg] if tab.is_a?(Hash)
    return true unless msg.is_a?(Hash) && JOB_CLASSES.include?(msg["class"])

    tab[:msg] = msg.except("args")
    true
  end
end
