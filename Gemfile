# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# prometheus-client's DirectFileStore needs CGI.parse, which moved to cgi/core in
# Ruby 4.0. A Rails host pulls it in transitively; the specs must ask for it.
gem "cgi"
gem "prometheus-client", "~> 4.0"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rubocop-config-umbrellio"
gem "yabeda-prometheus"
