module Admin
  # The contact-form spam quarantine: everything Akismet flagged, held for a month so a false
  # positive can be released instead of vanishing. Clean submissions never appear here — they go
  # straight to email from ContactMailJob.
  class ContactController < BaseController
    # GET /contact
    def index
      @messages = SpamQuarantine.new.all.map do |payload|
        SpamMessagePresenter.new(
          payload: payload,
          not_spam_path: contact_not_spam_path(payload["id"]),
          delete_path: contact_message_path(payload["id"])
        )
      end
    end

    # POST /contact/:id/not-spam
    #
    # Releases a message: it's removed from the queue and re-enters the normal pipeline, which
    # also reports the false positive back to Akismet.
    def not_spam
      message = SpamQuarantine.new.take(params[:id])
      return redirect_to(contact_path, status: :see_other, alert: "That message is no longer in the queue.") if message.nil?

      ContactMailJob.perform_async(
        message["name"],
        message["email"],
        message["message"],
        # Carries the original submission time into the email, which would otherwise report the
        # moment the message was released.
        (message["context"] || {}).merge("received_at" => message["received_at"]),
        true
      )

      redirect_to contact_path, status: :see_other, notice: "Message released — it's on its way to your inbox."
    end

    # DELETE /contact/:id
    def destroy
      SpamQuarantine.new.delete(params[:id])
      redirect_to contact_path, status: :see_other, notice: "Message deleted."
    end
  end
end
