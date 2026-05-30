# Static lookup tables for the weather widget, ported from the web app's data/*.yml.
# Loaded once at boot. Keys are symbolized: condition codes become symbols (e.g. :Rain),
# Beaufort levels stay integers (0..12) with symbol sub-keys.
CONDITIONS = YAML.load_file(Rails.root.join("config/conditions.yml"), symbolize_names: true).freeze
BEAUFORT = YAML.load_file(Rails.root.join("config/beaufort.yml"), symbolize_names: true).freeze
