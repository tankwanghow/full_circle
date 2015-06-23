class Holiday < ActiveRecord::Base
  validates_uniqueness_of :name, scope: :holidate
  validates_uniqueness_of :holidate, scope: :name

  include Searchable
  searchable content: [:name, :holidate]

  simple_audit username_method: :username do |r|
    {
      name: r.name,
      holidate: r.holidate
    }
  end
end
