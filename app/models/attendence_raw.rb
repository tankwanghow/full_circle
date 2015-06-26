class AttendenceRaw < ActiveRecord::Base
  belongs_to :employee
  validates_uniqueness_of :employee_id, scope: :timed_at
  validates_uniqueness_of :timed_at, scope: :employee_id

  def self.import file
    CSV.foreach(file, headers: false, col_sep: "\t") do |t|
      if !AttendenceRaw.where(employee_id: t[0]).where(timed_at: DateTime.parse(t[1])).exists?
        AttendenceRaw.create!(employee_id: t[0], timed_at: DateTime.parse(t[1]))
      end
    end
  end
end
