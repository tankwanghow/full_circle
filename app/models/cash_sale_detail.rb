class CashSaleDetail < ActiveRecord::Base
  belongs_to :cash_sale
  belongs_to :product
  belongs_to :product_packaging
  belongs_to :tax_code

  validates_presence_of :product_name1, :unit, :tax_code_code
  validates_numericality_of :quantity, greater_than: 0
  
  include ValidateBelongsTo
  validate_belongs_to :product, :name1
  validate_belongs_to :tax_code, :code

  def ex_gst_total
    ((quantity * unit_price) + discount).round(2)
  end

  def in_gst_total
    (ex_gst_total + gst).round(2)
  end

  def gst
    (gst_rate / 100 * ex_gst_total).round(2)
  end

  def goods_total
    (quantity * unit_price).round 2
  end

  def simple_audit_string
    [ product.name1, quantity, unit_price, discount, tax_code.try(:code), gst_rate ].join ' '
  end

  def unit
    product.unit if product
  end

  def transactions
    [product_transaction, gst_transaction].compact
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

private

  def product_transaction
    Transaction.new({
      doc: cash_sale, 
      account: product.sale_account, 
      transaction_date: cash_sale.doc_date, 
      note: cash_sale.customer.name1 + ' - ' + product.name1,
      amount: -ex_gst_total,
      user: User.current
    })
  end

  def gst_transaction
    if gst != 0
      Transaction.new({
        doc: cash_sale, 
        account: tax_code.gst_account, 
        transaction_date: cash_sale.doc_date, 
        note: cash_sale.customer.name1 + ' - GST on ' + product.name1,
        amount: -gst,
        user: User.current  
      })
    end
  end

end