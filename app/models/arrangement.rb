class Arrangement < ActiveRecord::Base
  belongs_to :sales_order
  belongs_to :purchase_order
  belongs_to :loading_order
  belongs_to :invoice
  belongs_to :pur_invoice

  scope :empty_with_sales_order, ->(val) { where(sales_order_id: val, purchase_order_id: nil, loading_order_id: nil, invoice_id: nil, pur_invoice_id: nil, quantity: 0) }

  def self.create_with_sales_orders! ids
    rtn = []
    ids.each do |id|
      arrangement = empty_with_sales_order(id.to_i).first
      if arrangement
        rtn << arrangement
      else
        rtn << create!(sales_order_id: id.to_i)
      end
    end
    rtn
  end
end
