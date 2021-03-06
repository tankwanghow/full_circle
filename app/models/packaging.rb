class Packaging < ActiveRecord::Base
  validates_presence_of :name
  has_many :product_packagings
  has_many :products, through: :product_packagings

  include Searchable
  searchable content: [:name, :product_packagings_audit_string]

  accepts_nested_attributes_for :product_packagings, allow_destroy: true

  simple_audit username_method: :username do |r|
    {
      name: r.name,
      packagings: r.product_packagings_audit_string
    }
  end

  include AuditString
  audit_string :product_packagings

end
