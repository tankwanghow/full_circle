class SalesOrder < ActiveRecord::Base
  belongs_to :customer, class_name: "Account"
  belongs_to :product
  belongs_to :product_packaging
  has_many :details, :class_name => "SalesOrderDetail"
  has_many :arrangements
  include ValidateBelongsTo
  validate_belongs_to :customer, :name1
  validate_belongs_to :product, :name1

  accepts_nested_attributes_for :details, allow_destroy: true
end