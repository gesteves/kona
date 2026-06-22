require "oj"

# Route JSON through Oj for speed. The read-through Redis cache parses on every hit and
# serializes on every write (ApplicationService#cached_json), and the services parse upstream
# response bodies — all hot paths.
Oj.mimic_JSON      # JSON.parse / JSON.generate (incl. symbolize_names) → Oj
Oj.optimize_rails  # ActiveSupport #to_json → Oj
