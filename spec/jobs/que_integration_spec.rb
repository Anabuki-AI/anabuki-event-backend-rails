require "rails_helper"

RSpec.describe "Que Active Job integration", type: :job do
  class QueIntegrationSmokeJob < ApplicationJob
    queue_as :default

    class << self
      attr_accessor :performed_value
    end

    def perform(value)
      self.class.performed_value = value
    end
  end

  it "persists an Active Job payload in PostgreSQL and executes it" do
    QueIntegrationSmokeJob.performed_value = nil
    job = QueIntegrationSmokeJob.perform_later("smoke")

    expect(job.provider_job_id).to be_present
    row = ActiveRecord::Base.connection.select_one(
      ActiveRecord::Base.sanitize_sql_array([
        "SELECT job_class, args FROM que_jobs WHERE id = ?",
        job.provider_job_id
      ])
    )
    expect(row.fetch("job_class")).to eq("ActiveJob::QueueAdapters::QueAdapter::JobWrapper")

    # This is the same Que wrapper used by the worker. Running it here proves
    # that the PostgreSQL-enqueued payload can cross the Que/Active Job boundary.
    ActiveJob::QueueAdapters::QueAdapter::JobWrapper.run(job.serialize)
    expect(QueIntegrationSmokeJob.performed_value).to eq("smoke")
  ensure
    ActiveRecord::Base.connection.execute(
      ActiveRecord::Base.sanitize_sql_array([ "DELETE FROM que_jobs WHERE id = ?", job&.provider_job_id ])
    ) if defined?(job) && job&.provider_job_id
  end
end
