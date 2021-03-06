# encoding: utf-8
class CreditNotePdf < Prawn::Document
  include Prawn::Helper

  def initialize(credit_notes, view, static_content=false)
    super(page_size: [210.mm, (295/2).mm], margin: [0.mm, 0.mm, 0.mm, 0.mm], skip_page_creation: true)
    @view = view
    @static_content = static_content
    draw credit_notes
  end

  def draw credit_notes
    for p in credit_notes
      @credit_note = p
      @total_pages = 1
      @page_end_at = 32.mm
      @detail_height = 4.mm
      @detail_y_start_at = 75.mm
      start_new_credit_note_page
      fill_color "000077"
      font_size 10 do
        draw_header
        draw_detail
      end
      draw_footer
      draw_page_number
      fill_color "000000"
    end
    self
  end

  def draw_static_content
    draw_text CompanyName, size: 18, style: :bold, at: [4.mm, 131.mm]
    draw_text @view.header_address_pdf(CompanyAddress), size: 9, at: [4.mm, 127.mm]
    draw_text @view.header_contact_pdf(CompanyAddress), size: 9, at: [4.mm, 123.mm]
    draw_text "CREDIT NOTE", style: :bold, size: 12, at: [155.mm, 124.mm]
    stroke_rounded_rectangle [4.mm, 119.mm], 202.mm, 35.mm, 3.mm
    draw_text "TO ACCOUNT", size: 8, at: [6.mm, 115.mm]
    stroke_vertical_line 119.mm, 84.mm, at: 120.mm
    draw_text "ACCOUNT ID", size: 8, at: [121.mm, 116.mm]
    stroke_horizontal_line 120.mm, 206.mm, at: 109.25.mm
    draw_text "NOTE DATE", size: 8, at: [121.mm, 105.5.mm]
    stroke_horizontal_line 120.mm, 206.mm, at: 100.5.mm
    draw_text "NOTE NO", size: 8, at: [121.mm, 97.mm]
    stroke_horizontal_line 120.mm, 206.mm, at: 91.75.mm
    draw_text "REFERENCE NO", size: 8, at: [121.mm, 88.5.mm]
    stroke_rounded_rectangle [4.mm, 84.mm], 202.mm, 55.mm, 3.mm
    draw_text "PARTICULARS", size: 8, at: [65.mm, 79.5.mm]
    draw_text "AMOUNT", size: 8, at: [175.mm, 79.5.mm]
    stroke_horizontal_line 4.mm, 206.mm, at: 77.mm
    stroke_vertical_line 84.mm, 29.mm, at: 154.mm
    stroke_horizontal_line 5.mm, 60.mm, at: 9.mm
    draw_text "Authorised By", size: 8, at: [6.mm, 25.mm]
    stroke_horizontal_line 150.mm, 205.mm, at: 9.mm
    draw_text "Prepare By", size: 8, at: [150.mm, 25.mm]
  end

  #Dynamic Content
  def draw_header
    text_box @credit_note.account.name1, at: [10.mm, 113.mm], size: 10, width: 100.mm, height: 20.mm, style: :bold
    if @credit_note.account.mailing_address
      address_box(self, @credit_note.account.mailing_address, [10.mm, 108.mm], width: 110.mm, height: 24.mm)
    end
    draw_text @view.docnolize(@credit_note.account.id), at: [150.mm, 112.mm], size: 10, style: :bold
    draw_text @credit_note.doc_date, at: [150.mm, 103.mm], style: :bold
    draw_text @view.docnolize(@credit_note.id), at: [150.mm, 94.5.mm], size: 15, style: :bold
  end

  def draw_page_number
    i = 0
    ((page_count - @total_pages + 1)..page_count).step(1) do |p|
      go_to_page p
      bounding_box [bounds.right - 30.mm, bounds.top - 8.mm], width: 30.mm, height: 5.mm do
        text "Page #{i+=1} of #{@total_pages}", size: 9
      end
    end
  end

  def draw_detail
    draw_pay_to_particulars
  end

  def draw_pay_to_particulars
    @detail_y = @detail_y_start_at
    @credit_note.particulars.each do |t|
      part_note = [t.particular_type.name_nil_if_note, t.note]
      qty = @view.number_with_precision(t.quantity, precision: 4, strip_insignificant_zeros: true, delimiter: ',') + t.unit
      price = @view.number_with_precision(t.unit_price, precision: 4, delimiter: ',')
      str = [part_note, qty, "X", price].compact.join(" ")

      bounding_box [8.mm, @detail_y], height: @detail_height, width: 140.mm do
        text_box str, overflow: :shrink_to_fit, valign: :center
      end

      bounding_box [155.mm, @detail_y], height: @detail_height, width: 50.mm do
        text_box (t.quantity * t.unit_price).to_money.format, overflow: :shrink_to_fit, align: :center, valign: :center
      end

      if t.gst != 0
        @detail_y = @detail_y - 4.mm
        bounding_box [15.mm, @detail_y + 0.5.mm], height: @detail_height, width: 100.mm do
          text_box "- GST #{t.tax_code.code} #{t.tax_code.rate}% X #{@view.number_with_precision(t.ex_gst_total, precision: 2, delimiter: ',')} = #{@view.number_with_precision(t.gst, precision: 2, delimiter: ',')}", overflow: :shrink_to_fit, valign: :center, size: 9
        end
      end

      @detail_y = @detail_y - @detail_height

      if @detail_y <= @page_end_at
        start_new_page_for_current_credit_note
        @detail_y = @detail_y_start_at
      end
    end
  end

  def draw_footer
    line_width 1
    stroke_horizontal_line 154.mm, 206.mm, at: @detail_y - 1.mm
    bounding_box [155.mm, @detail_y - 2.mm], height: 5.mm, width: 50.mm do
      text_box @credit_note.ex_gst_amount.to_money.format, overflow: :shrink_to_fit,
                align: :center, valign: :center, size: 11
    end
    bounding_box [102.mm, @detail_y - 2.mm], height: 5.mm, width: 50.mm do
      text_box "Total Excl. GST", overflow: :shrink_to_fit,
                align: :right, valign: :center, size: 11
    end
    stroke_horizontal_line 154.mm, 206.mm, at: @detail_y - 7.mm
    bounding_box [155.mm, @detail_y - 8.mm], height: 5.mm, width: 50.mm do
      text_box @credit_note.gst_amount.to_money.format, overflow: :shrink_to_fit,
                align: :center, valign: :center, size: 11
    end
    bounding_box [102.mm, @detail_y - 8.mm], height: 5.mm, width: 50.mm do
      text_box "Total GST", overflow: :shrink_to_fit,
                align: :right, valign: :center, size: 11
    end
    stroke_horizontal_line 154.mm, 206.mm, at: @detail_y - 13.mm
    bounding_box [155.mm, @detail_y - 14.mm], height: 5.mm, width: 50.mm do
      text_box @credit_note.in_gst_amount.to_money.format, overflow: :shrink_to_fit,
                align: :center, valign: :center, style: :bold, size: 11
    end
    bounding_box [102.mm, @detail_y - 14.mm], height: 5.mm, width: 50.mm do
      text_box "Total Incl. GST", overflow: :shrink_to_fit,
                align: :right, valign: :center, style: :bold, size: 11
    end
    stroke_horizontal_line 154.mm, 206.mm, at: @detail_y - 19.mm
  end

  def start_new_page_for_current_credit_note
    @total_pages = @total_pages + 1
    start_new_page
    draw_static_content if @static_content
    draw_header
  end

  def start_new_credit_note_page(options={})
    @total_pages = 1
    start_new_page
    draw_static_content if @static_content
  end
end
