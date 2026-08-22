require "oj"

# Use Oj for the JSON, because it is faster. The read-through Redis cache parses at each read and
# serializes at each write (refer to ApplicationService#cached_json), and each service parses the
# body of an upstream response. Each of those runs many times.
Oj.mimic_JSON      # JSON.parse / JSON.generate (incl. symbolize_names) → Oj
Oj.optimize_rails  # ActiveSupport #to_json → Oj
