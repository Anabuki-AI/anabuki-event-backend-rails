# spec/jobs/que_integration_spec.rb deliberately runs a real Que job outside
# any RSpec-managed transaction (that's the point of the integration test), so
# its writes are never rolled back like the rest of the suite's. When that job
# happens to touch audit-worthy state, the resulting AuditLog rows persist in
# the test database indefinitely and leak into unrelated examples that assert
# on AuditLog's full contents (exact arrays/counts/`.sole`). Clearing the
# table before every example keeps each example's audit assertions isolated
# regardless of what a real, non-transactional job run left behind earlier.
RSpec.configure do |config|
  config.before do
    AuditLog.delete_all
  end
end
