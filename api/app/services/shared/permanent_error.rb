# A failure that no retry can correct: an account that is not connected, a token that expired, a
# post with no words. A service or a job raises it, and ApplicationJob then puts the job in the Dead
# set at once and does not use the 24-hour retry budget.
class PermanentError < StandardError; end
