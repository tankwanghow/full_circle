class Arrangement < ActiveRecord::Base
  belongs_to :sales_order_detail
  belongs_to :purchase_order_detail
  belongs_to :loading_order_detail
  belongs_to :invoice_detail
  belongs_to :pur_invoice_detail

end
