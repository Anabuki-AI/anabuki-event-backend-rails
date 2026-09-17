require "rails_helper"

RSpec.describe "operator schema in the primary database", type: :model do
  let(:connection) { ApplicationRecord.connection }

  it "creates all operator tables and relationships in the primary database" do
    expect(ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "operator")).to be_nil
    expect(Operator::Identity.connection_db_config.name).to eq("primary")
    expect(Operator::DeviceSession.connection_db_config.name).to eq("primary")
    expect(Operator::OauthState.connection_db_config.name).to eq("primary")

    expect(connection.data_sources).to include(
      "operator_identities",
      "operator_device_sessions",
      "operator_oauth_states"
    )
    expect(connection.columns(:operator_identities).find { |column| column.name == "email" }.sql_type).to eq("text")
    expect(connection.columns(:operator_device_sessions).find { |column| column.name == "email" }.sql_type).to eq("text")

    foreign_key = connection.foreign_keys(:operator_device_sessions).find do |key|
      key.column == "operator_identity_id"
    end
    expect(foreign_key).to be_present
    expect(foreign_key.to_table).to eq("operator_identities")
  end
end
