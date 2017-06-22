require 'dry/core/class_attributes'

require 'rom/constants'
require 'rom/initializer'
require 'rom/relation/class_interface'

require 'rom/auto_curry'
require 'rom/pipeline'
require 'rom/mapper_registry'

require 'rom/relation/loaded'
require 'rom/relation/curried'
require 'rom/relation/composite'
require 'rom/relation/graph'
require 'rom/relation/wrap'
require 'rom/relation/materializable'
require 'rom/relation/commands'
require 'rom/association_set'

require 'rom/types'
require 'rom/schema'

module ROM
  # Base relation class
  #
  # Relation is a proxy for the dataset object provided by the gateway. It
  # can forward methods to the dataset, which is why the "native" interface of
  # the underlying gateway is available in the relation. This interface,
  # however, is considered private and should not be used outside of the
  # relation instance.
  #
  # Individual adapters sets up their relation classes and provide different APIs
  # depending on their persistence backend.
  #
  # Vanilla Relation class doesn't have APIs that are specific to ROM container setup.
  # When adapter Relation class inherits from this class, these APIs are added automatically,
  # so that they can be registered within a container.
  #
  # @see ROM::Relation::ClassInterface
  #
  # @api public
  class Relation
    # Default no-op output schema which is called in `Relation#each`
    NOOP_OUTPUT_SCHEMA = -> tuple { tuple }.freeze

    extend Initializer
    extend AutoCurry
    extend ClassInterface

    include Relation::Commands

    extend Dry::Core::ClassAttributes

    defines :adapter, :gateway, :schema_opts, :schema_class,
            :schema_attr_class, :schema_inferrer, :schema_dsl,
            :wrap_class, :auto_map, :auto_struct

    gateway :default

    auto_map true
    auto_struct false

    schema_opts EMPTY_HASH
    schema_dsl Schema::DSL
    schema_attr_class Schema::Attribute
    schema_class Schema
    schema_inferrer Schema::DEFAULT_INFERRER

    wrap_class Relation::Wrap

    include Dry::Equalizer(:name, :dataset)
    include Materializable
    include Pipeline

    # @!attribute [r] dataset
    #   @return [Object] dataset used by the relation provided by relation's gateway
    #   @api public
    param :dataset

    # @!attribute [r] schema
    #   @return [Schema] relation schema, defaults to class-level canonical
    #                    schema (if it was defined) and sets an empty one as
    #                    the fallback
    #   @api public
    option :schema, default: -> { self.class.schema || self.class.default_schema }

    # @!attribute [r] name
    #   @return [Object] The relation name
    #   @api public
    option :name, default: -> { self.class.schema ? self.class.schema.name : self.class.default_name }

    # @!attribute [r] input_schema
    #   @return [Object#[]] tuple processing function, uses schema or defaults to Hash[]
    #   @api private
    option :input_schema, default: -> { schema.to_input_hash }

    # @!attribute [r] output_schema
    #   @return [Object#[]] tuple processing function, uses schema or defaults to NOOP_OUTPUT_SCHEMA
    #   @api private
    option :output_schema, default: -> {
      schema.any?(&:read?) ? schema.to_output_hash : NOOP_OUTPUT_SCHEMA
    }

    # @!attribute [r] mappers
    #   @return [MapperRegistry] an optional mapper registry (empty by default)
    option :mappers, default: -> { MapperRegistry.new }

    # @!attribute [r] auto_struct
    #   @return [TrueClass,FalseClass] Whether or not tuples should be auto-mapped to structs
    #   @api private
    option :auto_struct, reader: true, default: -> { self.class.auto_struct }

    # @!attribute [r] auto_map
    #   @return [TrueClass,FalseClass] Whether or not a relation and its compositions should be auto-mapped
    #   @api private
    option :auto_map, reader: true, default: -> { self.class.auto_map }

    # @!attribute [r] commands
    #   @return [CommandRegistry] Command registry
    #   @api private
    option :commands, optional: true

    # @!attribute [r] meta
    #   @return [Hash] Meta data stored in a hash
    #   @api private
    option :meta, reader: true, default: -> { EMPTY_HASH }

    # Return schema attribute
    #
    # @example accessing canonical attribute
    #   users[:id]
    #   # => #<ROM::SQL::Attribute[Integer] primary_key=true name=:id source=ROM::Relation::Name(users)>
    #
    # @example accessing joined attribute
    #   tasks_with_users = tasks.join(users).select_append(tasks[:title])
    #   tasks_with_users[:title, :tasks]
    #   # => #<ROM::SQL::Attribute[String] primary_key=false name=:title source=ROM::Relation::Name(tasks)>
    #
    # @return [Schema::Attribute]
    #
    # @api public
    def [](name)
      schema[name]
    end

    # Yields relation tuples
    #
    # Every tuple is processed through Relation#output_schema, it's a no-op by default
    #
    # @yield [Hash]
    #
    # @return [Enumerator] if block is not provided
    #
    # @api public
    def each(&block)
      return to_enum unless block

      if auto_struct?
        mapper.(dataset.map { |tuple| output_schema[tuple] }).each { |struct| yield(struct) }
      else
        dataset.each { |tuple| yield(output_schema[tuple]) }
      end
    end

    # Composes with other relations
    #
    # @param [Array<Relation>] others The other relation(s) to compose with
    #
    # @return [Relation::Graph]
    #
    # @api public
    def graph(*others)
      Graph.build(self, others)
    end

    # Combine with other relations
    #
    # @overload combine(*associations)
    #   Composes relations using configured associations

    #   @example
    #     users.combine(:tasks, :posts)
    #   @param *associations [Array<Symbol>] A list of association names
    #
    # @return [Relation]
    #
    # @api public
    def combine(*args)
      graph(*nodes(*args))
    end

    # @api private
    def nodes(*args)
      args.map do |arg|
        case arg
        when Symbol
          node(arg)
        when Hash
          arg.reduce(self) { |r, (k, v)| r.node(k).combine(*v) }
        when Array
          arg.map { |opts| nodes(opts) }
        end
      end.flatten(0)
    end

    # @api public
    def node(name)
      assoc = associations[name]
      other = assoc.node
      other.eager_load(assoc)
    end

    # @api public
    def eager_load(assoc)
      relation = assoc.prepare(self)

      if assoc.override?
        relation.(assoc)
      else
        relation.preload_assoc(assoc)
      end
    end

    # @api private
    auto_curry def preload_assoc(assoc, other)
      assoc.preload(self, other)
    end

    # Wrap other relations
    #
    # @example
    #   tasks.wrap(:owner)
    #
    # @param [Hash] options
    #
    # @return [RelationProxy]
    #
    # @api public
    def wrap(*names)
      wrap_class.new(self, names.map { |n| associations[n].wrap })
    end

    # Loads relation
    #
    # @return [Relation::Loaded]
    #
    # @api public
    def call
      Loaded.new(self)
    end

    # Materializes a relation into an array
    #
    # @return [Array<Hash>]
    #
    # @api public
    def to_a
      to_enum.to_a
    end

    # Returns if this relation is curried
    #
    # @return [false]
    #
    # @api private
    def curried?
      false
    end

    # Returns if this relation is a graph
    #
    # @return [false]
    #
    # @api private
    def graph?
      false
    end

    # Return if this is a wrap relation
    #
    # @return [false]
    #
    # @api private
    def wrap?
      false
    end

    # Returns true if a relation has schema defined
    #
    # @return [TrueClass, FalseClass]
    #
    # @api private
    def schema?
      ! schema.empty?
    end

    # Return a new relation with provided dataset and additional options
    #
    # Use this method whenever you need to use dataset API to get a new dataset
    # and you want to return a relation back. Typically relation API should be
    # enough though. If you find yourself using this method, it might be worth
    # to consider reporting an issue that some dataset functionality is not available
    # through relation API.
    #
    # @example with a new dataset
    #   users.new(users.dataset.some_method)
    #
    # @example with a new dataset and options
    #   users.new(users.dataset.some_method, other: 'options')
    #
    # @param [Object] dataset
    # @param [Hash] new_opts Additional options
    #
    # @api public
    def new(dataset, new_opts = EMPTY_HASH)
      if new_opts.empty?
        opts = options
      elsif new_opts.key?(:schema)
        opts = options.reject { |k, _| k == :input_schema || k == :output_schema }.merge(new_opts)
      else
        opts = options.merge(new_opts)
      end

      self.class.new(dataset, opts)
    end

    # Returns a new instance with the same dataset but new options
    #
    # @example
    #   users.with(output_schema: -> tuple { .. })
    #
    # @param new_options [Hash]
    #
    # @return [Relation]
    #
    # @api private
    def with(opts)
      new_options =
        if opts.key?(:meta)
          opts.merge(meta: meta.merge(opts[:meta]))
        else
          opts
        end

      new(dataset, options.merge(new_options))
    end

    # Return all registered relation schemas
    #
    # This holds all schemas defined via `view` DSL
    #
    # @return [Hash<Symbol=>Schema>]
    #
    # @api public
    def schemas
      @schemas ||= self.class.schemas
    end

    # Return schema's association set (empty by default)
    #
    # @return [AssociationSet] Schema's association set (empty by default)
    #
    # @api public
    def associations
      schema.associations
    end

    # Returns AST for the wrapped relation
    #
    # @return [Array]
    #
    # @api public
    def to_ast
      @__ast__ ||= [:relation, [name.relation, attr_ast, meta_ast]]
    end

    # @api private
    def attr_ast
      schema.map { |t| t.to_read_ast }
    end

    # @api private
    def meta_ast
      meta = self.meta.merge(dataset: name.dataset)
      meta[:model] = false unless auto_struct? || meta[:model]
      meta
    end

    # @api private
    def auto_map?
      (auto_map || auto_struct) && !meta[:combine_type]
    end

    # @api private
    def auto_struct?
      auto_struct && !meta[:combine_type]
    end

    # @api private
    def mapper
      mappers[to_ast]
    end

    # @api private
    def wraps
      @__wraps__ ||= meta.fetch(:wraps, EMPTY_ARRAY)
    end

    # Maps the wrapped relation with other mappers available in the registry
    #
    # @overload map_with(model)
    #   Map tuples to the provided custom model class
    #
    #   @example
    #     users.as(MyUserModel)
    #
    #   @param [Class>] model Your custom model class
    #
    # @overload map_with(*mappers)
    #   Map tuples using registered mappers
    #
    #   @example
    #     users.map_with(:my_mapper, :my_other_mapper)
    #
    #   @param [Array<Symbol>] mappers A list of mapper identifiers
    #
    # @overload map_with(*mappers, auto_map: true)
    #   Map tuples using auto-mapping and custom registered mappers
    #
    #   If `auto_map` is enabled, your mappers will be applied after performing
    #   default auto-mapping. This means that you can compose complex relations
    #   and have them auto-mapped, and use much simpler custom mappers to adjust
    #   resulting data according to your requirements.
    #
    #   @example
    #     users.map_with(:my_mapper, :my_other_mapper, auto_map: true)
    #
    #   @param [Array<Symbol>] mappers A list of mapper identifiers
    #
    # @return [RelationProxy] A new relation proxy with pipelined relation
    #
    # @api public
    def map_with(*names, **opts)
      super(*names).with(opts)
    end

    # Return a new relation that will map its tuples to instance of the provided class
    #
    # @example
    #   users.map_to(MyUserModel)
    #
    # @param [Class] klass Your custom model class
    #
    # @return [Relation::Composite]
    #
    # @api public
    def map_to(klass, **opts)
      with(opts.merge(meta: { model: klass }))
    end

    # Return a new relation with an aliased name
    #
    # @example
    #   users.as(:people)
    #
    # @param [Class] klass Your custom model class
    #
    # @return [Relation::Composite]
    #
    # @api public
    def as(aliaz)
      with(name: name.as(aliaz))
    end

    # @return [Symbol] The wrapped relation's adapter identifier ie :sql or :http
    #
    # @api private
    def adapter
      self.class.adapter
    end

    # Return name of the source gateway of this relation
    #
    # @return [Symbol]
    #
    # @api private
    def gateway
      self.class.gateway
    end

    # @api private
    def foreign_key(name)
      attr = schema.foreign_key(name.dataset)

      if attr
        attr.name
      else
        # TODO: remove this once ManyToOne uses a different query
        :"#{Dry::Core::Inflector.singularize(name.dataset)}_id"
      end
    end

    private

    # Hook used by `Pipeline` to get the class that should be used for composition
    #
    # @return [Class]
    #
    # @api private
    def composite_class
      Relation::Composite
    end

    # @api private
    def wrap_class
      self.class.wrap_class
    end
  end
end
