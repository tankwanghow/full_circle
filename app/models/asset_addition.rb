class AssetAddition < ActiveRecord::Base
  include SharedHelpers
  belongs_to :asset, class_name: "FixedAsset", foreign_key: "fixed_asset_id"
  has_many :disposals, class_name: "AssetDisposal", order: 'entry_date', dependent: :destroy
  has_many :depreciations, class_name: "AssetDepreciation", order: 'entry_date', dependent: :destroy
  validates_presence_of :final_amount, :entry_date, :amount

  accepts_nested_attributes_for :disposals, allow_destroy: true, reject_if: proc { |attr| attr['amount'].to_f == 0 }
  accepts_nested_attributes_for :depreciations, allow_destroy: true, reject_if: proc { |attr| attr['amount'].to_f == 0 }

  scope :active, -> { joins(asset: :account).where("accounts.status != ?", 'Dormant') }

  include AuditString
  audit_string :disposals, :depreciations

  simple_audit username_method: :username do |r|
    {
      year: r.entry_date,
      amount: r.amount,
      final_amount: r.final_amount,
      depreciations: r.depreciations_audit_string,
      disposals: r.disposals_audit_string
    }
  end

  def generate_annual_depreciation year
    values = annual_depreciation_for(year)
    if values.count > 0
      values.each { |t| depreciations.build(t) }
    end
  end

  def annual_depreciation_for year
    rtnval = []
    (entry_date.year..year).each do |t|
      edate = "#{t}-#{ClosingMonth}-#{ClosingDay}".to_date
      if !depreciation_for_year_exists?(t)
        dep = depreciation_for(edate)
        rtnval << { entry_date: edate, amount: dep } if dep > 0
      end
    end
    rtnval
  end

  def net_book_value_at in_date=prev_close_date(Date.today)
    amount - cum_depreciation_at(in_date) - cum_disposal_at(in_date)
  end

  def cum_depreciation_at in_date=prev_close_date(Date.today)
    depreciations.inject(0) do |sum, p| 
      (sum + p.amount) if p.entry_date <= in_date
    end || 0
  end

  def cum_disposal_at in_date=prev_close_date(Date.today)
    disposals.inject(0) do |sum, p| 
      (sum + p.amount) if p.entry_date <= in_date
    end || 0
  end

private

  def depreciation_for_year_exists?(year)
    depreciations.detect { |t| t.entry_date.year == year }
  end

  def depreciation_for in_date
    if can_depreciate_according_to_rate? in_date
      (cost(in_date) * asset.depreciation_rate).round(2)
    else
      cost(in_date) - cum_depreciation_at(in_date) - final_amount
    end
  end

  def cost in_date
    amount - cum_disposal_at(in_date)
  end

  def can_depreciate_according_to_rate? in_date
    cum_depreciation_at(in_date) + (cost(in_date) * asset.depreciation_rate).round(2) <= amount - final_amount
  end

  def fully_depreciated? in_date
    cum_depreciation_at(in_date) + final_amount >= cost(in_date)
  end
  
end