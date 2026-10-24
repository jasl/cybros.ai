module Rho
  module Env
    # Local shared resources outlive a replaced pool. Their leases end only
    # when the handler and result hooks exit, including after cancellation or timeout.
    class Admission
      Rule = Data.define(:resource, :limit) do
        def initialize(resource:, limit: 1)
          resource = resource.to_s
          limit = Integer(limit)
          raise ArgumentError, "admission needs a resource and positive limit" if resource.empty? || !limit.positive?

          super(resource: resource.freeze, limit: limit)
        end
      end
      Lease = Data.define(:owner, :rule) do
        def acquire = owner.acquire

        def release
          owner.release
          owner.retire
          nil
        end
      end

      def initialize
        @mutex = Mutex.new
        @held = Hash.new(0)
        @listeners = {}
      end

      def reserve(rule)
        @mutex.synchronize do
          return nil if @held[rule.resource] >= rule.limit

          @held[rule.resource] += 1
          owner = Extensions::Resources.new(extension: rule.resource)
          owner.own { release(rule) }
          owner.acquire
          Lease.new(owner: owner, rule: rule)
        end
      end

      def release(rule)
        listeners = @mutex.synchronize do
          @held[rule.resource] -= 1
          @held.delete(rule.resource) if @held[rule.resource].zero?
          @listeners.values.dup
        end
        listeners.each(&:call)
        nil
      end

      def subscribe(key, &listener) = @mutex.synchronize { @listeners[key] = listener }
      def unsubscribe(key) = @mutex.synchronize { @listeners.delete(key) }
    end
  end
end
