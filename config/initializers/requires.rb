require "core_ext"
require "fileutils"
require "diff-display/lib/diff-display"
require 'oauth/oauth'
gem "ruby-yadis", ">=0"
if defined?JRUBY_VERSION
  gem 'maruku'
  require 'maruku'
else
  gem "rdiscount", ">=0"
  require 'rdiscount'
end
silence_warnings do
  if defined?JRUBY_VERSION
    BlueCloth = Maruku
  else
    BlueCloth = RDiscount
  end
end
