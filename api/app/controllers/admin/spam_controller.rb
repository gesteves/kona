module Admin
  # The spam quarantine of the contact form: each message that Akismet marked as spam or that
  # ContactModeration marked as abusive. The app holds them for a month, thus the owner can send a
  # correct message that a check marked, and that message does not go away. A message with no mark
  # never appears here: ContactMailJob sends it directly as an email.
  class SpamController < BaseController
    # GET /spam
    def index
      @messages = SpamQuarantine.new.all.map do |payload|
        SpamMessagePresenter.new(
          payload: payload,
          not_spam_path: spam_not_spam_path(payload["id"]),
          delete_path: spam_message_path(payload["id"])
        )
      end
    end

    # POST /spam/:id/not-spam
    #
    # Sends a message: the code removes it from the queue and puts it in the normal path again. For
    # an Akismet mark it also tells Akismet that the mark was incorrect. Claude has no such report.
    def not_spam
      message = SpamQuarantine.new.take(params[:id])
      return redirect_to(spam_path, status: :see_other, alert: t("admin.spam_flash.gone")) if message.nil?

      context = message["context"] || {}

      if SpamQuarantine.reason_of(message) == SpamQuarantine::AKISMET
        ContactHamJob.perform_async(message["name"], message["email"], message["message"], context)
      end

      ContactMailJob.perform_async(
        message["name"],
        message["email"],
        message["message"],
        # This puts the first submission time in the email. Without it, the email would give the
        # time when the owner sent the message.
        context.merge("received_at" => message["received_at"]),
        true
      )

      redirect_to spam_path, status: :see_other, notice: t("admin.spam_flash.released")
    end

    # DELETE /spam/:id
    def destroy
      SpamQuarantine.new.delete(params[:id])
      redirect_to spam_path, status: :see_other, notice: t("admin.spam_flash.deleted")
    end
  end
end
