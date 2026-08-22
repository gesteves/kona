module Widgets
  # The base controller of the /widgets/* endpoints, which give plain HTML fragments for the static
  # site. Each one needs the API_TOKEN bearer token, and the proxy of the web app adds it. Thus the
  # origin is closed to the public and a scanner gets a fast 401 before any work.
  class BaseController < TokenGatedController
    include UpstreamIsolation

    # The shape of a Contentful entry id. Each other value in an `:id` segment can match no true
    # entry, and the origin rate limit does not apply to /widgets/*. Thus an id in a path with no
    # check is the one way left to make many cache entries. Keep this check before each operation
    # that uses an id.
    CONTENTFUL_ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

    private

    # @return [String, nil] The `:id` parameter when it has the shape of a Contentful entry id, or
    #   nil.
    def contentful_id_param
      id = params[:id].to_s
      id if id.match?(CONTENTFUL_ID_FORMAT)
    end
  end
end
