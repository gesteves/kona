require "ostruct"

# Recursively wraps parsed JSON (Hashes/Arrays) in OpenStructs so it can be read with
# dot notation, the way the Middleman `data.*` objects were. This lets the weather
# helpers be ported almost verbatim. Missing keys return nil (like OpenStruct/Middleman).
module DeepOstruct
  module_function

  def wrap(obj)
    case obj
    when Hash
      OpenStruct.new(obj.transform_values { |v| wrap(v) })
    when Array
      obj.map { |v| wrap(v) }
    else
      obj
    end
  end
end
