# frozen_string_literal: true

# Mechanical migration for the common two-language literal pattern:
#   L.locale == 'en' ? 'English' : '繁體中文'
# becomes L.pick(...), whose zh_CN branch is handled centrally.
#
# It intentionally touches only literal-to-literal conditions. Expressions and
# nested widget branches require human review.

string_literal = /'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"/m
equals_english = /L\.locale\s*==\s*'en'\s*\?\s*(?<en>#{string_literal})\s*:\s*(?<zh>#{string_literal})/m
not_english = /L\.locale\s*!=\s*'en'\s*\?\s*(?<zh>#{string_literal})\s*:\s*(?<en>#{string_literal})/m
is_english_variable = /(?<![\w.])isEn\s*\?\s*(?<en>#{string_literal})\s*:\s*(?<zh>#{string_literal})/m

changed_files = 0
replacements = 0

Dir['lib/{screens,widgets}/**/*.dart'].sort.each do |path|
  source = File.read(path)
  migrated = source.gsub(equals_english) do
    replacements += 1
    "L.pick(en: #{Regexp.last_match[:en]}, zhTW: #{Regexp.last_match[:zh]})"
  end
  migrated = migrated.gsub(not_english) do
    replacements += 1
    "L.pick(en: #{Regexp.last_match[:en]}, zhTW: #{Regexp.last_match[:zh]})"
  end
  migrated = migrated.gsub(is_english_variable) do
    replacements += 1
    "L.pick(en: #{Regexp.last_match[:en]}, zhTW: #{Regexp.last_match[:zh]})"
  end
  next if migrated == source

  File.write(path, migrated)
  changed_files += 1
end

puts "Migrated #{replacements} literal conditions in #{changed_files} files."
