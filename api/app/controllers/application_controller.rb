class ApplicationController < ActionController::Base
  # Only the catch-all route below uses this controller. The CSRF check is off, thus a scanner probe
  # that is not a GET, for example a POST to /api/.env, gets a clean 404 and not a 422 forgery
  # error.
  skip_forgery_protection

  # Answers the catch-all route for each path with no other route. It gives the same plain-text 404
  # as lib/plain_text_exceptions.rb, but as a normal controller response. Thus lograge writes one
  # clean status=404 line and not an ActionController::RoutingError backtrace. That keeps the scanner
  # probes out of the fly.io logs.
  def route_not_found
    render plain: "404 Not Found\n", status: :not_found
  end
end
