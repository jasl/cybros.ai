require "json"
require "tempfile"
require_relative "process_runner"

module E2E
  # Opt-in scale fixture for the Until restart journey. It adds unrelated
  # history ahead of the real goal, in that journey's isolated databases.
  module RecoveryScale
    SEED = <<~'RUBY'.freeze
      options = JSON.parse($stdin.read)
      size = Integer(options.fetch("size"))
      raise "invalid recovery fixture size" unless (1..200_000).cover?(size)
      connection = ActiveRecord::Base.lease_connection
      database = connection.select_value("SELECT current_database()")
      raise "recovery fixture requires an isolated E2E database" unless database.include?("e2e")
      workspace = Workspace.find_by!(public_id: options.fetch("workspace"))
      owner = User.find_by!(public_id: options.fetch("agent"))
      other = User.create!(account: owner.account, kind: "agent", steward: owner.steward,
        display_name: "Recovery scale fixture", agent_identifier: "fixture.recovery-scale")
      base = [Run.maximum(:id), Variant.maximum(:id), Turn.maximum(:id), Conversation.maximum(:id)].compact.max.to_i + 1000
      lo, hi = base + 1, base + size
      account, workspace_id, owner_id, other_id = owner.account_id, workspace.id, owner.id, other.id
      speaker_id = Speakers::Resolve.member(account: owner.account, user: owner).id
      connection.transaction do
        connection.execute(<<~SQL)
          INSERT INTO conversations(id,account_id,workspace_id,creating_user_id,answering_user_id,last_activity_at,archived_at,access_default,created_at,updated_at)
          SELECT i,#{account},#{workspace_id},#{owner_id},#{other_id},now(),CASE WHEN i%11=0 THEN now() END,'full',now(),now()
          FROM generate_series(#{lo},#{hi}) i
        SQL
        connection.execute(<<~SQL)
          INSERT INTO turns(id,account_id,conversation_id,position,kind,role,status,speaker_id,control_owner_user_id,answering_user_id,created_at,updated_at)
          SELECT i,#{account},i,0,'reply','assistant','completed',#{speaker_id},#{owner_id},CASE WHEN i%97=0 THEN #{owner_id} ELSE #{other_id} END,now(),now()
          FROM generate_series(#{lo},#{hi}) i
        SQL
        connection.execute(<<~SQL)
          INSERT INTO variants(id,account_id,turn_id,position,status,source,created_at,updated_at)
          SELECT i,#{account},i,0,'completed','initial',now(),now() FROM generate_series(#{lo},#{hi}) i
        SQL
        connection.execute(<<~SQL)
          INSERT INTO runs(id,account_id,workspace_id,creating_user_id,variant_id,status,approval_mode,created_at,updated_at)
          SELECT i,#{account},#{workspace_id},#{owner_id},i,CASE WHEN i%10<2 THEN 'running' ELSE 'completed' END,'bypass',now(),now()
          FROM generate_series(#{lo},#{hi}) i
        SQL
        %w[conversations turns variants runs].each do |table|
          connection.execute("SELECT setval(pg_get_serial_sequence('#{table}','id'), (SELECT max(id) FROM #{table}))")
        end
      end
      connection.execute("ANALYZE")
      plans = []
      connection.unprepared_statement do
        queries = []
        callback = ->(*args) {
          payload = args.last
          queries << payload[:sql] if payload[:sql].start_with?("SELECT") && !payload[:cached]
        }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
          Runs::Candidates.new(user: owner, agent_public_id: owner.public_id).call
        end
        queries.each do |sql|
          plans << { sql: sql, plan: JSON.parse(connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{sql}")) }
        end
      end
      File.write(options.fetch("report"), JSON.pretty_generate(
        history: size, active: Run.where(status: Runs::Candidates::SOURCE_STATUSES).count, first_page_queries: plans.length, plans: plans))
      puts "recovery scale fixture: #{size} historical Runs"
    RUBY

    def self.seed(handle:, size:, workspace:, agent:, report:)
      Tempfile.create(["recovery-scale", ".rb"]) do |script|
        script.write(SEED)
        script.flush
        status = ProcessRunner.run("bundle", "exec", "rails", "runner", script.path,
          env: handle.fetch("env"), chdir: handle.fetch("nexus_root"), timeout: 120,
          stdin: JSON.generate(size: size, workspace: workspace, agent: agent, report: report))
        raise "recovery scale fixture failed" unless status.success?
      end
    end
  end
end
