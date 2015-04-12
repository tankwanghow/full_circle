class PaymentsController < ApplicationController
  before_filter :warn_doc_date, only: [:create, :update]

  def edit
    begin
      @payment = Payment.not_matched.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to edit_matching_payment_path
    end
  end

  def new
    @payment = Payment.new(doc_date: Date.today, pay_from_name1: 'Cash In Hand')
    @payment.pay_to_particulars.build particular_type_name: 'Note'
  end

  def show
    begin
      @payment = Payment.not_matched.find(params[:id])
      @static_content = params[:static_content]
    rescue ActiveRecord::RecordNotFound
      redirect_to matching_payment_path(params)
    end
  end

  def create
    @payment = Payment.new(params[:payment])
    if @payment.save
      flash[:success] = "Payment '##{@payment.id}' created successfully."
      redirect_to is_matching? ? edit_matching_payment_path(@payment) : edit_payment_path(@payment)
    else
      flash.now[:error] = "Failed to create Payment."
      render template: payment_template_path + 'new'
    end
  end

  def update
    @payment = Payment.find(params[:id])
    if @payment.update_attributes(params[:payment])
      flash[:success] = "Payment '##{@payment.id}' updated successfully."
      redirect_to is_matching? ? edit_matching_payment_path(@payment) : edit_payment_path(@payment)
    else
      flash.now[:error] = "Failed to update Payment."
      render template: payment_template_path + 'edit'
    end
  end

  def new_or_edit
    if Payment.not_matched.last
      redirect_to edit_payment_path(Payment.not_matched.last)
    else
      redirect_to new_payment_path
    end
  end

  def typeahead_collector
    render json: typeahead_result(params[:term], "collector", Payment)
  end

private

  def is_matching?
    params[:matcher_account_element]
  end

  def payment_template_path
    is_matching? ? 'matching_payments/' : 'payments/'
  end
end
