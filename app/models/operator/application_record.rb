class Operator::ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true

  # All operator auth data lives in the dedicated operator database.
  connects_to database: { writing: :operator }
end
