defmodule FullCircleWeb.ReportLive.EAFormPrint do
  use FullCircleWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    [
      nosiri,
      nomajikanE,
      year,
      tin,
      lhdnbrh,
      a1,
      a2,
      a3,
      a4,
      a5,
      a6,
      a7,
      a8,
      a9a,
      a9b,
      b1a,
      b1b,
      b1cname,
      b1c,
      b1d,
      b1e,
      b1fdari,
      b1fhingga,
      b1f,
      b2a,
      b2b,
      b2,
      b3nyata,
      b3,
      b4alamat,
      b4,
      b5,
      b6,
      c1,
      c2,
      jumlah,
      d1,
      d2,
      d3,
      d4,
      d5a,
      d5b,
      d6,
      e1name,
      e1,
      e2,
      f,
      tarikh,
      nama,
      pos,
      address,
      phone
    ] =
      params["data"] |> String.split("|")

    {:ok,
     socket
     |> assign(
       page_title: gettext("Print"),
       nosiri: nosiri,
       nomajikanE: nomajikanE,
       year: year,
       tin: tin,
       lhdnbrh: lhdnbrh,
       a1: a1,
       a2: a2,
       a3: a3,
       a4: a4,
       a5: a5,
       a6: a6,
       a7: a7,
       a8: a8,
       a9a: a9a,
       a9b: a9b,
       b1a: b1a,
       b1b: b1b,
       b1cname: b1cname,
       b1c: b1c,
       b1d: b1d,
       b1e: b1e,
       b1fdari: b1fdari,
       b1fhingga: b1fhingga,
       b1f: b1f,
       b2a: b2a,
       b2b: b2b,
       b2: b2,
       b3nyata: b3nyata,
       b3: b3,
       b4alamat: b4alamat,
       b4: b4,
       b5: b5,
       b6: b6,
       c1: c1,
       c2: c2,
       jumlah: jumlah,
       d1: d1,
       d2: d2,
       d3: d3,
       d4: d4,
       d5a: d5a,
       d5b: d5b,
       d6: d6,
       e1name: e1name,
       e1: e1,
       e2: e2,
       f: f,
       tarikh: tarikh,
       nama: nama,
       pos: pos,
       address: address,
       phone: phone
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="print-me" class="print-here">
      {style(assigns)}
      <div class="page">
        <div class="field" style="top: 55px; left: 125px; text-align: center; width: 108px;">{@nosiri}</div>
        <div class="field" style="top: 57px; left: 125px; text-align: center; width: 108px;">{@nomajikanE}</div>
        <div class="field" style="top: 36px; left: 488px; text-align: center; width: 35px;">{@year}</div>
        <div class="field" style="top: -2px; left: 550px; text-align: center; width: 190px;">{@tin}</div>
        <div class="field" style="top: -5px; left: 635px; text-align: center; width: 110px;">{@lhdnbrh}</div>
        <div class="field" style="top: 31px; left: 340px; text-align: center; width: 400px;">{@a1}</div>
        <div class="field" style="top: 32px; left: 190px; text-align: center; width: 200px;">{@a2}</div>
        <div class="field" style="top: 10px; left: 575px; text-align: center; width: 165px;">{@a3}</div>
        <div class="field" style="top: 10px; left: 190px; text-align: center; width: 200px;">{@a4}</div>
        <div class="field" style="top: -12px; left: 575px; text-align: center; width: 165px;">{@a5}</div>
        <div class="field" style="top: -13px; left: 190px; text-align: center; width: 200px;">{@a6}</div>
        <div class="field" style="top: -35px; left: 575px; text-align: center; width: 165px;">{@a7}</div>
        <div class="field" style="top: -23px; left: 240px; text-align: center; width: 145px;">{zsd(@a8)}</div>
        <div class="field" style="top: -40px; left: 575px; text-align: center; width: 165px;">{@a9a}</div>
        <div class="field" style="top: -41px; left: 575px; text-align: center; width: 165px;">{@a9b}</div>
        <div class="field" style="top: 4px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b1a, 2)}
        </div>
        <div class="field" style="top: 2px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b1b, 2)}
        </div>
        <div class="field" style="top: -1px; left: 535px; text-align: center; width: 100px;">{@b1cname}</div>
        <div class="field" style="top: -21px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b1c, 2)}
        </div>
        <div class="field" style="top: -23px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b1d, 2)}
        </div>
        <div class="field" style="top: -25px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b1e, 2)}
        </div>
        <div class="field" style="top: -26px; left: 255px; text-align: center; width: 140px;">{@b1fdari}</div>
        <div class="field" style="top: -47px; left: 430px; text-align: center; width: 140px;">{@b1fhingga}</div>
        <div class="field" style="top: -68px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b1f, 2)}
        </div>

        <div class="field" style="top: -53px; left: 228px; text-align: center; width: 160px;">{@b2a}</div>
        <div class="field" style="top: -54px; left: 228px; text-align: center; width: 160px;">{@b2b}</div>
        <div class="field" style="top: -76px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b2, 2)}
        </div>
        <div class="field" style="top: -78px; left: 285px; text-align: center; width: 350px;">{@b3nyata}</div>
        <div class="field" style="top: -98px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b3, 2)}
        </div>

        <div class="field" style="top: -100px; left: 258px; text-align: center; width: 378px;">{@b4alamat}</div>
        <div class="field" style="top: -121px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b4, 2)}
        </div>

        <div class="field" style="top: -123px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b5, 2)}
        </div>
        <div class="field" style="top: -125px; left: 645px; text-align: right; width: 95px;">
          {zsd(@b6, 2)}
        </div>

        <div class="field" style="top: -97px; left: 645px; text-align: right; width: 95px;">
          {zsd(@c1, 2)}
        </div>
        <div class="field" style="top: -97px; left: 645px; text-align: right; width: 95px;">
          {zsd(@c2, 2)}
        </div>
        <div
          class="field"
          style="font-weight: bold; top: -92px; left: 645px; text-align: right; width: 95px;"
        >
          {zsd(@jumlah, 2)}
        </div>

        <div class="field" style="top: -70px; left: 645px; text-align: right; width: 95px;">
          {zsd(@d1, 2)}
        </div>
        <div class="field" style="top: -71px; left: 645px; text-align: right; width: 95px;">
          {zsd(@d2, 2)}
        </div>
        <div class="field" style="top: -74px; left: 645px; text-align: right; width: 95px;">
          {zsd(@d3, 2)}
        </div>
        <div class="field" style="top: -76px; left: 645px; text-align: right; width: 95px;">
          {zsd(@d4, 2)}
        </div>

        <div class="field" style="top: -65px; left: 475px; text-align: right; width: 160px;">
          {zsd(@d5a, 2)}
        </div>

        <div class="field" style="top: -66px; left: 475px; text-align: right; width: 160px;">
          {zsd(@d5b, 2)}
        </div>

        <div class="field" style="top: -70px; left: 645px; text-align: right; width: 95px;">
          {zsd(@d6, 2)}
        </div>

        <div class="field" style="top: -41px; left: 225px; text-align: center; width: 510px;">
          {@e1name}
        </div>

        <div class="field" style="top: -45px; left: 645px; text-align: right; width: 95px;">
          {zsd(@e1, 2)}
        </div>
        <div class="field" style="top: -47px; left: 645px; text-align: right; width: 95px;">
          {zsd(@e2, 2)}
        </div>

        <div class="field" style="font-weight: bold; top: -37px; left: 645px; text-align: right; width: 95px;">
          {zsd(@f, 2)}
        </div>
        <div class="field" style="top: -12px; left: 440px; text-align: center; width: 295px;">{@nama}</div>
        <div class="field" style="top: -13px; left: 440px; text-align: center; width: 295px;">{@pos}</div>
        <div class="field" style="top: -16px; left: 440px; text-align: center; width: 295px;">{@address}</div>
        <div class="field" style="top: -19px; left: 440px; text-align: center; width: 295px;">{@phone}</div>
        <div class="field" style="top: -60px; left: 100px; text-align: center; width: 145px;">{@tarikh}</div>
      </div>
    </div>
    """
  end

  defp zsd(num, pre \\ 0) do
    if(num |> Decimal.new() |> Decimal.eq?(Decimal.new("0")),
      do: "-",
      else:
        num |> Number.Delimit.number_to_delimited(delimiter: ",", separator: ".", precision: pre)
    )
  end

  defp style(assigns) do
    ~H"""
    <style>
      .page { width: 210mm; height: 297mm; position: relative;
              background-image: url('/images/ea2023-1.jpg');
              background-size: 210mm 297mm;  }

      .field { position: relative; border: 1px dotted transparent;}

      @media print {
        @page { size: A4; margin: 0mm; }
        .page { width: 210mm; height: 296.5mm; position: relative;
              background-image: url('/images/ea2023-1.jpg');
              background-size: 210mm 296.5mm;  }
        .field { position: relative;  border: 1px dotted transparent;}
      }
    </style>
    """
  end
end
