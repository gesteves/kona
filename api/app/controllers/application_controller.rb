class ApplicationController < ActionController::Base
  # Only the catch-all route below renders through this controller. Skip CSRF so non-GET
  # scanner probes (POST /api/.env, etc.) get a clean 404 instead of a 422 forgery error.
  skip_forgery_protection

  # Handles the catch-all route for unmatched paths. Returns the same plain-text 404 as
  # lib/plain_text_exceptions.rb, but as a normal controller response so the request logs as
  # one clean status=404 line (via lograge) instead of an ActionController::RoutingError
  # backtrace. Keeps scanner probes from spamming the fly.io logs.
  def route_not_found
    render plain: "404 Not Found\n", status: :not_found
  end
end
