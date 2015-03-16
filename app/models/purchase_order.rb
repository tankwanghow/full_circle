class PurchaseOrder < ActiveRecord::Base
  belongs_to :supplier, class_name: "Account"
  belongs_to :product
  belongs_to :product_packaging
  has_many :details, :class_name => "PurchaseOrderDetail"
  has_many :arrangements
  include ValidateBelongsTo
  validate_belongs_to :supplier, :name1
  validate_belongs_to :product, :name1

  accepts_nested_attributes_for :details, allow_destroy: true
end