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
        <div class="field" style="top: 75px; left: 150px;">{@bosstaxno}</div>
        <div class="field" style="top: 58px; left: 495px;">{@year}</div>
        <div class="field" style="top: 22px; left: 600px;">{@taxno}</div>
        <div class="field" style="top: 20px; left: 650px;">{@branch}</div>
        <div class="field" style="top: 58px; left: 400px;">{@name}</div>
        <div class="field" style="top: 60px; left: 250px;">{@position}</div>
        <div class="field" style="top: 59px; left: 250px;">{@ic}</div>
        <div class="field" style="top: 59px; left: 250px;">{@epf_no}</div>
        <div class="field" style="top: 73px; left: 300px;">{@children}</div>
        <div class="field" style="top: 142px; left: 660px;">{@income}</div>
        <div class="field" style="top: 159px; left: 550px;">
          {if Decimal.to_float(@angpow) > 0, do: "Ang Pow", else: "-"}
        </div>
        <div class="field" style="top: 140px; left: 660px;">{@angpow}</div>
        <div class="field" style="top: 250px; left: 450px;">
          {if Decimal.to_float(@bik) > 0, do: "Kereta", else: "-"}
        </div>
        <div class="field" style="top: 230px; left: 660px;">{@bik}</div>
        <div class="field" style="top: 362px; left: 660px; font-weight: bold;">{@total}</div>
        <div class="field" style="top: 386px; left: 660px;">{@pcb}</div>
        <div class="field" style="top: 488px; left: 670px;">{@childrended}</div>
        <div class="field" style="top: 519px; left: 470px;">
          {if Decimal.to_float(@epf) > 0, do: "KWSP", else: "-"}
        </div>
        <div class="field" style="top: 517px; left: 660px;">{@epf}</div>
        <div class="field" style="top: 516px; left: 680px;">{@socso}</div>
        <div class="field" style="top: 640px; left: 140px;">{@gendate}</div>
        <div class="field" style="top: 550px; left: 500px;">{@by}</div>
        <div class="field" style="top: 555px; left: 540px;">{@bypos}</div>
        <div class="field" style="top: 553px; left: 470px; width: 295px;">{@address}</div>
        <div class="field" style="top: 552px; left: 540px;">{@phone}</div>
      </div>
    </div>
    """
  end

  defp style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; height: 290mm; position: relative;
              background-image: url('/images/ea2023-1.jpg');
              background-size: 210mm 290mm;  }

      .field { position: relative; }

      @media print {
        @page { size: A4; margin: 0mm; }
        .page { width: 210mm; height: 290mm; position: relative;
              background-image: url('/images/ea2023-1.jpg');
              background-size: 210mm 290mm;  }
              .field { position: relative; }
      }
    </style>
    """
  end
end
