# The parent class of each contact-form job. ⚠️ A contact message must never go away, thus these
# jobs use the default retries of Sidekiq (25 attempts, approximately 21 days) and not the 24-hour
# `retry_for` of ApplicationJob. The Claude subject line is the only step that fails soft.
#
# ContactJobArgsFilter removes the arguments of each subclass from a Bugsnag report, because they
# hold the data of a sender.
class ContactJob < ApplicationJob
  # A nil value makes Sidekiq count the attempts.
  sidekiq_options retry_for: nil
end
