class SalesOrder < ActiveRecord::Base
  belongs_to :customer, class_name: "Account"
  belongs_to :product
  belongs_to :product_packaging
  has_many :arrangements
  include ValidateBelongsTo
  validate_belongs_to :customer, :name1
  validate_belongs_to :product, :name1

  include PgSearch
  pg_search_scope :search_by_terms, associated_against: { product: :name1, customer: :name1 }, against: :note

  after_create :create_arrangement

  def assigned_purchase_order
    arrangements.last.purchase_order
  end

  def assigned_loading_order
    arrangements.last.loading_order
  end

  def unit
    product.try(:unit)
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

  def self.search hash
    search_by_hash hash
  end

  private

  def create_arrangement
    Arrangement.create! sales_order_id: id
  end

  def self.search_by_hash hash
    search_by_fulfilled(hash[:fulfilled]).
    merge(search_by_order_at(hash[:order_at], hash[:days])).
    merge(search_by_deliver_at(hash[:deliver_at], hash[:days])).
    merge(
      if !hash[:terms].blank?
        search_by_terms hash[:terms]
      else
        where('1=1')
      end).order('id desc')
  end

  def self.search_by_order_at date, days
    days ||= 0
    if !date.blank?
      dstart = (date.to_date - days.to_i).to_date
      dend   = (date.to_date + days.to_i).to_date
      where('doc_date >= ?', dstart).where('doc_date <= ?', dend)
    else
      where('1=1')
    end
  end

  def self.search_by_deliver_at date, days
    days ||= 0
    if !date.blank?
      dstart = (date.to_date - days.to_i).to_date
      dend   = (date.to_date + days.to_i).to_date
      where('deliver_at >= ?', dstart).where('deliver_at <= ?', dend)
    else
      where('1=1')
    end
  end

  def self.search_by_fulfilled fulfilled=false
    where(fulfilled: fulfilled)
  end

end