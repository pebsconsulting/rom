module ROM

  # Exposes defined repositories, schema, relations and mappers
  #
  # @api public
  class Env
    include Adamantium::Flat

    attr_reader :repositories, :schema, :relations, :mappers

    # @api private
    def initialize(repositories, schema, relations, mappers)
      @repositories = repositories
      @schema = schema
      @relations = relations
      @mappers = mappers
    end

    # Returns a reader with access to defined mappers
    #
    # @example
    #
    #   rom.read(:users).adults.to_a
    #
    # @api public
    def read(name)
      mappers[name]
    end

    # @api private
    def [](name)
      repositories.fetch(name)
    end

    # @api private
    def respond_to_missing?(name, include_private = false)
      repositories.key?(name)
    end

    private

    # @api private
    def method_missing(name, *args)
      repositories.fetch(name)
    end
  end

end