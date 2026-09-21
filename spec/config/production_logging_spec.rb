require "spec_helper"
require "tmpdir"
require "stringio"
require "que"
require_relative "../../lib/production_logging"

RSpec.describe ProductionLogging do
  around do |example|
    mask = File.umask
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "production.log")
      example.run
    ensure
      @logger&.close
      File.umask(mask)
    end
  end

  def build(**overrides)
    @stdout = StringIO.new
    @logger = described_class.build(env: { "RAILS_LOG_PATH" => @path, "RAILS_LOG_LEVEL" => "debug" }.merge(overrides), stdout: @stdout)
  end

  it "broadcasts every severity with request tags to both sinks" do
    build
    @logger.tagged("request-123") do
      %i[debug info warn error fatal unknown].each { |level| @logger.public_send(level, "message-#{level}") }
    end
    [ @stdout.string, File.read(@path) ].each do |output|
      %i[debug info warn error fatal unknown].each do |level|
        expect(output.scan("[request-123] message-#{level}").size).to eq(1)
      end
    end
    expect(@logger.level).to eq(Logger::DEBUG)
    expect(@logger.broadcasts.map(&:level)).to eq([ Logger::DEBUG, Logger::DEBUG ])
  end

  it "applies the requested threshold to both sinks" do
    build("RAILS_LOG_LEVEL" => "warn")
    @logger.info("excluded")
    @logger.warn("included")
    [ @stdout.string, File.read(@path) ].each do |output|
      expect(output).to include("included")
      expect(output).not_to include("excluded")
    end
  end

  it "keeps stdout-only behavior when no path is configured" do
    build("RAILS_LOG_PATH" => nil)
    @logger.debug("stdout only")
    expect(@stdout.string).to include("stdout only")
    expect(File).not_to exist(@path)
  end

  it "rotates at the configured threshold and bounds retained files with restrictive modes" do
    File.write(@path, "")
    File.chmod(0o666, @path)
    build("RAILS_LOG_ROTATION_COUNT" => "3", "RAILS_LOG_ROTATION_SIZE" => "128")
    20.times { |i| @logger.info("#{i}:#{'x' * 150}") }
    files = Dir.glob("#{@path}*")
    expect(files.size).to eq(3)
    expect(File.read(@path)).to include("19:")
    expect(files.map { |file| File.stat(file).mode & 0o777 }).to all(eq(0o640))
    expect(files.map { |file| File.read(file) }.join).not_to include("\n0:")
  end

  it "rejects invalid rotation settings" do
    %w[RAILS_LOG_ROTATION_COUNT RAILS_LOG_ROTATION_SIZE].each do |key|
      %w[0 -1 garbage 1.5].each do |value|
        expect { build(key => value) }.to raise_error(ArgumentError, "#{key} must be a positive integer")
      end
    end
  end

  it "filters Que JSON events without changing job data or hiding diagnostic metadata" do
    build
    original_logger, original_formatter = Que.logger, Que.log_formatter
    Que.logger = @logger
    Que.log_formatter = described_class.que_formatter([ :token ])
    job = { id: 42, job_class: "ExampleJob", args: [ "raw-positional", { nested: "secret" } ], kwargs: { name: "raw-keyword" } }.freeze
    Que.log(event: :job_worked, level: :debug, job: job, token: "raw-token", elapsed: 0.1)
    Que.log(event: :job_errored, level: :error, job: job.transform_keys(&:to_s), error_message: "failure")
    [ @stdout.string, File.read(@path) ].each do |output|
      expect(output).to include('"id":42', '"event":"job_worked"', '"event":"job_errored"', '"elapsed":0.1', '"args":["[FILTERED]","[FILTERED]"]', '"kwargs":{"name":"[FILTERED]"}', '"token":"[FILTERED]"')
      expect(output).not_to match(/raw-positional|raw-keyword|raw-token|secret/)
    end
    expect(job[:args].first).to eq("raw-positional")
  ensure
    Que.logger, Que.log_formatter = original_logger, original_formatter
  end
end
