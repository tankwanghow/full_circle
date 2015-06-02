class ApplicationController < ActionController::Base
  include Authentication
  include SentientController

  protect_from_forgery
  before_filter :login_required

  # rescue_from Exception do |e|
  #   msg = "#{e.class.name} -> #{e.message}"
  #   flash[:error] = msg.html_safe
  #   redirect_to exception_redirection_path
  # end

private

  def warn_doc_date
    model = params[:controller].singularize
    doc_date = params[model][:doc_date] ? params[model][:doc_date].to_date : nil
    if doc_date
      if doc_date > Date.today + 2
        flash[:notice] = "Future Entry. Ignore this warning if you realy mean it."
      elsif doc_date < Date.today - 30
        flash[:notice] = "Pass Entry. Ignore this warning if you realy mean it."
      end
    end
  end

  def admin_lock_check object
    raise 'Need Administrator Right!' if object.admin_lock and !current_user.is_admin?
  end

  def store_param name
    if params[name]
      session[name.to_sym] = {}
      params[name].each do |k,v|
        session[name.to_sym][k.to_sym] = v.blank? ? nil : v
      end
    else
      session[name.to_sym] ||= {}
    end
  end

  def exception_redirection_path
    if !request.env['HTTP_REFERER'].blank?
      :back
    else
      root_path
    end
  end

  def typeahead_result term, field, klass
    term1 = "%#{term}%"
    term2 = "%#{term.scan(/(\w)/).flatten.join('%')}%"
    results = klass.uniq.where("#{field} ilike ?", term1).limit(10).order("#{field}").pluck("#{field}")
    if results.count == 0
      results = klass.uniq.where("#{field} ilike ?", term2).limit(10).order("#{field}").pluck("#{field}")
    end
    return results
  end

end