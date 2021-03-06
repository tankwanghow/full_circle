class BatchPrintDocsController < ApplicationController
  def index
    store_param :batch_print_search
    @docs = Document.searchable_by(session[:batch_print_search]).page(params[:page]).per(15).order('updated_at desc')
    flash.now[:warning] = "Can print on kind of documents a time." if @docs.map { |t| t.searchable_type }.uniq.count > 1
  end

  def print
    @docs = params[:doc_ids].select { |k, v| v.to_i == 1 }.map { |k,v| k.to_i }
    if params[:commit] == 'Print'
      @static_content = true
    else
      @static_content = false
    end
    if @docs.count == 0
      render text: 'Empty'
    end
  end

end
