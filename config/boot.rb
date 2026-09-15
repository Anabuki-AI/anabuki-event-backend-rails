ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
# Bootsnap's native cache cannot open this project's Windows paths reliably.
# Keep it enabled for the Linux environments used by CI and deployment.
require "bootsnap/setup" unless Gem.win_platform?
