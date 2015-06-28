class AttendenceRaw < ActiveRecord::Base
  belongs_to :employee
  validates_uniqueness_of :employee_id, scope: :timed_at
  validates_uniqueness_of :timed_at, scope: :employee_id

  validate do |t| 
    errors.add "timed_at", "unacceptable" unless AttendenceRaw.valid_raw_attendence?(t.employee_id, t.timed_at)
  end

  def self.import file
    raw = CSV.read(file, headers: false, col_sep: "\t")
    raw.sort_by { |t| t[0] + t[1] }.each do |k|
      if valid_raw_attendence? k[0], DateTime.parse("#{k[1]} #{Time.zone}")
        AttendenceRaw.create!(employee_id: k[0], timed_at: DateTime.parse("#{k[1]} #{Time.zone}"), flag: deciding_flag(k[0], DateTime.parse("#{k[1]} #{Time.zone}")))
      end
    end
  end

private

  def self.deciding_flag employee, timed
    above_punch = AttendenceRaw.where(employee_id: employee).where('timed_at < ?', timed).order(:timed_at).last
    if above_punch == nil || above_punch.flag == 'OUT'
      return 'IN'
    else
      return 'OUT'
    end
  end

  def self.valid_raw_attendence? employee=employee_id, timed=timed_at
    is_unique_entry?(employee, timed) && correct_minits_between_punches?(employee, timed)
  end

  def self.correct_minits_between_punches? employee, timed
    employee_attendence = AttendenceRaw.where(employee_id: employee)
    correct_minits_above_punches?(employee_attendence, timed) && correct_minits_below_punches?(employee_attendence, timed)
  end

  def self.correct_minits_above_punches? employee_attendence, timed
    above_punch = employee_attendence.where('timed_at < ?', timed).order(:timed_at).last.try(:timed_at_before_type_cast)
    correct_minits_punches? timed, above_punch
  end

  def self.correct_minits_below_punches? employee_attendence, timed
    below_punch = employee_attendence.where('timed_at > ?', timed).order(:timed_at).first.try(:timed_at_before_type_cast)
    correct_minits_punches? timed, below_punch
  end

  def self.correct_minits_punches? timed, check_punch
    minits_in_between_punch = 5
    if check_punch == nil
      return true
    elsif (timed.to_f - DateTime.parse(check_punch).to_f).abs/60 <= minits_in_between_punch
      return false
    else
      return true
    end
  end

  def self.is_unique_entry? employee, timed
    !AttendenceRaw.where(employee_id: employee).where(timed_at: timed).exists?
  end
end