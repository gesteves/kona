module Api
  # Base controller for the /api/* structured-data endpoints, which accept or return data
  # rather than the widget markup under Widgets::BaseController. Bearer-gated by default;
  # deliberately public endpoints skip_before_action the check.
  class BaseController < TokenGatedController
  end
end
