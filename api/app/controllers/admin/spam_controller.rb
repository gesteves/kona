module Admin
  # The spam quarantine of the contact form: each message that Akismet marked. The app holds them
  # for a month, thus the owner can send a correct message that Akismet marked, and that message
  # does not go away. A message with no mark never appears here: ContactMailJob sends it directly as
  # an email.
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
    # Sends a message: the code removes it from the queue and puts it in the normal path again, and
    # that path also tells Akismet that its mark was incorrect.
    def not_spam
      message = SpamQuarantine.new.take(params[:id])
      return redirect_to(spam_path, status: :see_other, alert: "That message is no longer in the queue.") if message.nil?

      ContactMailJob.perform_async(
        message["name"],
        message["email"],
        message["message"],
        # This puts the first submission time in the email. Without it, the email would give the
        # time when the owner sent the message.
        (message["context"] || {}).merge("received_at" => message["received_at"]),
        true
      )

      redirect_to spam_path, status: :see_other, notice: "Message released — it's on its way to your inbox."
    end

    # DELETE /spam/:id
    def destroy
      SpamQuarantine.new.delete(params[:id])
      redirect_to spam_path, status: :see_other, notice: "Message deleted."
    end
  end
end
