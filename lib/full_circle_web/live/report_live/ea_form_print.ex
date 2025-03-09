defmodule FullCircleWeb.ReportLive.EAFormPrint do
  use FullCircleWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    [
      name,
      position,
      taxno,
      ic,
      epf_no,
      children,
      childrended,
      income,
      angpow,
      bik,
      epf,
      pcb,
      socso,
      bosstaxno,
      gendate,
      year,
      by,
      bypos,
      address,
      phone,
      branch
    ] =
      params["data"] |> String.split("|")

    dec_income = to_decimal(income)
    dec_bik = to_decimal(bik)
    dec_angpow = to_decimal(angpow)

    total = dec_income |> Decimal.add(dec_bik) |> Decimal.add(dec_angpow)

    {:ok,
     socket
     |> assign(
       page_title: gettext("Print"),
       name: name,
       position: position,
       taxno: taxno,
       ic: ic,
       epf_no: epf_no,
       children: children,
       childrended: childrended,
       income: dec_income,
       angpow: dec_angpow,
       bik: dec_bik,
       epf: to_decimal(epf),
       pcb: pcb,
       socso: socso,
       total: total,
       bosstaxno: bosstaxno,
       gendate: gendate,
       year: year,
       by: by,
       bypos: bypos,
       address: address,
       phone: phone,
       branch: branch
     )}
  end

  defp to_decimal(str) do
    if Decimal.parse(str) != :error,
      do: Decimal.new(str) |> Decimal.round(2),
      else: Decimal.new("0")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {style(assigns)}
      <div class="page">
        <div class="field" style="top: 140px; left: 700px;">{@bosstaxno}</div>
        <div class="field" style="top: 140px; left: 1045px;">{@year}</div>
        <div class="field" style="top: 140px; left: 1200px;">{@branch}</div>
        <div class="field" style="top: 200px; left: 950px;">{@name}</div>
        <div class="field" style="top: 220px; left: 800px;">{@position}</div>
        <div class="field" style="top: 125px; left: 1150px;">{@taxno}</div>
        <div class="field" style="top: 238px; left: 800px;">{@ic}</div>
        <div class="field" style="top: 256px; left: 800px;">{@epf_no}</div>
        <div class="field" style="top: 285px; left: 850px;">{@children}</div>
        <div class="field" style="top: 855px; left: 1220px;">{@childrended}</div>
        <div class="field" style="top: 376px; left: 1220px;">{@income}</div>
        <div :if={Decimal.to_float(@angpow) > 0} class="field" style="top: 413px; left: 1100px;">Ang Pow</div>
        <div class="field" style="top: 413px; left: 1220px;">{@angpow}</div>
        <div :if={Decimal.to_float(@bik) > 0} class="field" style="top: 542px; left: 1000px;">Kereta</div>
        <div class="field" style="top: 542px; left: 1220px;">{@bik}</div>
        <div class="field" style="top: 692px; left: 1220px; font-weight: bold;">{@total}</div>
        <div :if={Decimal.to_float(@epf) > 0} class="field" style="top: 905px; left: 1000px;">KWSP</div>
        <div class="field" style="top: 922px; left: 1220px;">{@epf}</div>
        <div class="field" style="top: 735px; left: 1220px;">{@pcb}</div>
        <div class="field" style="top: 940px; left: 1230px;">{@socso}</div>
        <div class="field" style="top: 1088px; left: 680px;">{@gendate}</div>
        <div class="field" style="top: 1012px; left: 1060px;">{@by}</div>
        <div class="field" style="top: 1035px; left: 1060px;">{@bypos}</div>
        <div class="field" style="top: 1053px; left: 1000px; width: 295px;">{@address}</div>
        <div class="field" style="top: 1090px; left: 1090px;">{@phone}</div>
      </div>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; min-height: 290mm; padding: 5mm;
              background-image: url('/images/ea2023-1.jpg');
              background-size: contain;
              background-repeat: no-repeat;
              background-position: center; }

      .field {
        position: absolute;
      }

      @media print {
        @page { size: A4; margin: 0mm; }
        body { width: 210mm; height: 290mm; margin: 0mm; }
        html { margin: 0mm; }
        .page { padding-left: 5mm; padding-right: 5mm; page-break-after: always;} }
    </style>
    """
  end
end
