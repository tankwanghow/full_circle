class PurchaseOrderDetail < ActiveRecord::Base
  belongs_to :purchase_order
  belongs_to :product
  belongs_to :product_packaging
  has_many :arrangements
  
  validates_presence_of :product_name1, :unit
  validates_numericality_of :quantity, greater_than: 0
  
  include ValidateBelongsTo
  validate_belongs_to :product, :name1
  
  def simple_audit_string
    [ product.name1, packaging_name, note, quantity, unit_price ].join ' '
  end

  def unit
    product.unit if product
  end

  def balance
    0
  end

  def packaging_name
    product_packaging.pack_qty_name if product_packaging
  end

  def packaging_name= val
    if !val.blank?
      pid = ProductPackaging.find_product_package(product_id, val).try(:id)
      if pid
        self.product_packaging_id = pid
      else
        errors.add 'packaging_name', 'not found!'
      end
    else
      self.product_packaging_id = nil
    end
  end

end