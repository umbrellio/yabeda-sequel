# frozen_string_literal: true

module Yabeda
  module Sequel
    # Builds the `db` label for a Sequel::Database.
    #
    # The label has to be stable across processes: an object_id-based fallback
    # would mint a distinct series per worker and blow up cardinality in the
    # multiprocess metric store.
    module Naming
      class << self
        def call(db)
          name = db.opts[:database].to_s
          return name unless name.empty?

          db.database_type.to_s
        end
      end
    end
  end
end
