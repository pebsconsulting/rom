RSpec.describe ROM::Plugins::Schema::Timestamps do
  let(:relation) { ROM::Relation::Name[:users] }

  let(:schema_dsl) do
    ROM::Schema::DSL.new(relation)
  end

  subject(:schema) { schema_dsl.call }

  it 'adds timestamp attributes' do
    ts_attribute = -> name { ROM::Attribute.new(ROM::Types::Time.meta(source: relation), name: name) }

    schema_dsl.use :timestamps

    expect(schema[:created_at]).to eql(ts_attribute.(:created_at))
    expect(schema[:updated_at]).to eql(ts_attribute.(:updated_at))
  end

  it 'supports custom names' do
    schema_dsl.use :timestamps
    schema_dsl.timestamps :created_on, :updated_on

    expect(schema.to_h.keys).to eql(%i(created_on updated_on))
  end

  it 'supports custom types' do
    schema_dsl.use :timestamps, type: ROM::Types::Date
    dt_attribute = -> name { ROM::Attribute.new(ROM::Types::Date.meta(source: relation), name: name) }

    expect(schema[:created_at]).to eql(dt_attribute.(:created_at))
    expect(schema[:updated_at]).to eql(dt_attribute.(:updated_at))
  end

  it 'supports custom names with options' do
    schema_dsl.use :timestamps, attributes: %i(created_on updated_on)

    expect(schema.to_h.keys).to eql(%i(created_on updated_on))
  end
end
