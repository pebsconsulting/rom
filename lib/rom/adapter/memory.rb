module ROM
  class Adapter

    class Memory < Adapter
      attr_reader :connection

      def self.schemes
        [:memory]
      end

      class Dataset
        include Charlatan.new(:data)

        def each(&block)
          return to_enum unless block
          data.each(&block)
        end

        def restrict(criteria = nil, &block)
          if criteria
            find_all { |tuple| criteria.all? { |k, v| tuple[k] == v } }
          else
            find_all { |tuple| yield(tuple) }
          end
        end

        def project(*names)
          map { |tuple| tuple.reject { |key,_| names.include?(key) } }
        end

        def order(*names)
          sort_by { |tuple| tuple.values_at(*names) }
        end

        def insert(tuple)
          data << tuple
        end

        def header
          []
        end
      end

      class Storage
        attr_reader :data

        def initialize(*)
          super
          @data = {}
        end

        def [](name)
          data[name] ||= Dataset.new([])
        end
      end

      def initialize(*args)
        super
        @connection = Storage.new
      end

      def [](name)
        connection[name]
      end

      Adapter.register(self)
    end

  end
end