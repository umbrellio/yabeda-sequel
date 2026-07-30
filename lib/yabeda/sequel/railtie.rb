# frozen_string_literal: true

module Yabeda
  module Sequel
    # Starts the sampler for Rails-hosted processes — Sidekiq, Sneakers, and Puma
    # in single mode all need nothing further.
    #
    # Clustered Puma additionally needs fork hooks in config/puma.rb, because a
    # gem cannot reach into them. See the README.
    class Railtie < ::Rails::Railtie
      config.after_initialize do
        Yabeda::Sequel.start! if Yabeda::Sequel.config.autostart
      end
    end
  end
end
