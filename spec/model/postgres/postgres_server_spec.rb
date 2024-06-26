# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe PostgresServer do
  subject(:postgres_server) {
    described_class.new
  }

  let(:vm) {
    instance_double(
      Vm,
      sshable: instance_double(Sshable),
      mem_gib: 8,
      ephemeral_net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64"),
      private_subnets: [
        instance_double(
          PrivateSubnet,
          net4: NetAddr::IPv4Net.parse("172.0.0.0/26"),
          net6: NetAddr::IPv6Net.parse("fdfa:b5aa:14a3:4a3d::/64")
        )
      ]
    )
  }

  before do
    allow(postgres_server).to receive(:vm).and_return(vm)
  end

  it "generates configure_hash" do
    expect(postgres_server).to receive(:timeline).and_return(instance_double(PostgresTimeline, blob_storage: "dummy-blob-storage"))
    postgres_server.timeline_access = "push"
    configure_hash = {
      configs: {
        listen_addresses: "'*'",
        max_connections: "200",
        superuser_reserved_connections: "3",
        shared_buffers: "2048MB",
        work_mem: "1MB",
        maintenance_work_mem: "512MB",
        max_parallel_workers: "4",
        max_parallel_workers_per_gather: "2",
        max_parallel_maintenance_workers: "2",
        min_wal_size: "80MB",
        max_wal_size: "5GB",
        random_page_cost: "1.1",
        effective_cache_size: "6144MB",
        effective_io_concurrency: "200",
        tcp_keepalives_count: "4",
        tcp_keepalives_idle: "2",
        tcp_keepalives_interval: "2",
        ssl: "on",
        ssl_min_protocol_version: "TLSv1.3",
        ssl_cert_file: "'/dat/16/data/server.crt'",
        ssl_key_file: "'/dat/16/data/server.key'",
        log_timezone: "'UTC'",
        log_directory: "'pg_log'",
        log_filename: "'postgresql.log'",
        log_truncate_on_rotation: "true",
        logging_collector: "on",
        timezone: "'UTC'",
        lc_messages: "'C.UTF-8'",
        lc_monetary: "'C.UTF-8'",
        lc_numeric: "'C.UTF-8'",
        lc_time: "'C.UTF-8'",
        archive_mode: "on",
        archive_command: "'/usr/bin/wal-g wal-push %p --config /etc/postgresql/wal-g.env'",
        archive_timeout: "60"
      },
      private_subnets: [
        {
          net4: "172.0.0.0/26",
          net6: "fdfa:b5aa:14a3:4a3d::/64"
        }
      ]
    }

    expect(postgres_server.configure_hash).to eq(configure_hash)
  end

  it "generates configure_hash with additonal fields for restoring servers" do
    expect(postgres_server).to receive(:timeline).and_return(instance_double(PostgresTimeline, blob_storage: "dummy-blob-storage"))
    postgres_server.timeline_access = "fetch"
    expect(postgres_server).to receive(:resource).and_return(instance_double(PostgresResource, restore_target: "2023-10-25 00:00"))
    expect(postgres_server.configure_hash[:configs]).to include(
      recovery_target_time: "'2023-10-25 00:00'",
      restore_command: "'/usr/bin/wal-g wal-fetch %f %p --config /etc/postgresql/wal-g.env'"
    )
  end

  it "does not set archival related configs if blob storage is not configured" do
    expect(postgres_server).to receive(:timeline).and_return(instance_double(PostgresTimeline, blob_storage: nil))
    postgres_server.timeline_access = "push"
    expect(postgres_server.configure_hash[:configs]).not_to include(
      archive_mode: "on"
    )
  end

  it "initiates a new health monitor session" do
    forward = instance_double(Net::SSH::Service::Forward)
    expect(forward).to receive(:local_socket)
    session = instance_double(Net::SSH::Connection::Session)
    expect(session).to receive(:forward).and_return(forward)
    expect(postgres_server.vm.sshable).to receive(:start_fresh_session).and_return(session)
    postgres_server.init_health_monitor_session
  end

  it "checks pulse" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      db_connection: DB
    }
    t = Time.now - 30
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: t
    }

    expect(postgres_server).not_to receive(:incr_checkup)
    postgres_server.check_pulse(session: session, previous_pulse: pulse)
  end

  it "increments checkup semaphore if pulse is down for a while" do
    session = {
      ssh_session: instance_double(Net::SSH::Connection::Session),
      db_connection: instance_double(Sequel::Postgres::Database)
    }
    t = Time.now - 30
    pulse = {
      reading: "down",
      reading_rpt: 5,
      reading_chg: t
    }

    expect(session[:db_connection]).to receive(:[]).and_raise(Sequel::DatabaseConnectionError)
    expect(postgres_server).to receive(:incr_checkup)
    postgres_server.check_pulse(session: session, previous_pulse: pulse)
  end
end
