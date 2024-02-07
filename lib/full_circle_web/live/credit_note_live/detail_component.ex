defmodule FullCircleWeb.CreditNoteLive.DetailComponent do
  use FullCircleWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={@klass}>
      <div class="font-medium flex flex-row text-center mt-2 tracking-tighter">
        <div class="detail-header w-[30%]">
          <%= gettext("Description") %>
        </div>
        <div class="detail-header w-[10%]"><%= gettext("Quantity") %></div>
        <div class="detail-header w-[8%]"><%= gettext("Price") %></div>
        <div class="detail-header w-[10%]">
          <%= gettext("Desc Amt") %>
        </div>
        <div class="detail-header w-[20%]">
          <%= gettext("Account") %>
        </div>
        <div class="detail-header w-[8%]"><%= gettext("TxCode") %></div>
        <div class="detail-header w-[8%]">
          <%= gettext("Tax%") %>
        </div>
        <div class="detail-header w-[8%]">
          <%= gettext("TaxAmt") %>
        </div>
        <div class="detail-header w-[14%]"><%= gettext("Amount") %></div>
        <div class="detail-setting-col  mt-1 text-blue-500 grow-0 shrink-0"></div>
      </div>

      <.inputs_for :let={dtl} field={@form[@detail_name]}>
        <div class={"flex flex-row #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
          <div class="w-[30%]"><.input field={dtl[:descriptions]} /></div>
          <div class="w-[10%]">
            <.input
              phx-hook="calculatorInput"
              klass="text-right"
              field={dtl[:quantity]}
              step="0.0001"
            />
          </div>
          <div class="w-[8%]">
            <.input
              phx-hook="calculatorInput"
              klass="text-right"
              field={dtl[:unit_price]}
              step="0.0001"
            />
          </div>
          <div class="w-[10%]">
            <.input type="number" field={dtl[:desc_amount]} readonly tabindex="-1" />
          </div>
          <div class="w-[20%]">
            <.input
              field={dtl[:account_name]}
              phx-hook="tributeAutoComplete"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <.input type="hidden" field={dtl[:account_id]} />
          <div class="w-[8%]">
            <.input
              field={dtl[:tax_code_name]}
              phx-hook="tributeAutoComplete"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=#{@taxcodetype}&name="}
            />
          </div>
          <.input type="hidden" field={dtl[:tax_code_id]} />
          <div class="w-[8%]">
            <.input type="number" field={dtl[:tax_rate]} step="0.0001" />
          </div>
          <div class="w-[8%]">
            <.input type="number" field={dtl[:tax_amount]} readonly tabindex="-1" />
          </div>
          <div class="w-[14%]">
            <.input type="number" field={dtl[:line_amount]} readonly tabindex="-1" />
          </div>
          <div class="detail-setting-col mt-1 text-rose-500">
            <.link phx-click={:delete_detail} phx-value-index={dtl.index} tabindex="-1">
              <.icon name="hero-trash-solid" class="h-5 w-5" />
            </.link>
            <.input type="hidden" field={dtl[:delete]} value={"#{dtl[:delete].value}"} />
          </div>
        </div>
      </.inputs_for>

      <div class="flex flex-row">
        <div class="mt-1 detail-desc-col text-orange-500 text-left">
          <.link phx-click={:add_detail} class="hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Detail") %>
          </.link>
        </div>
        <div class="w-[10%] text-right px-1 pt-1">
          <%= gettext("Desc Total") %>
        </div>
        <div class="detail-amt-col text-right px-1 pt-1">
          <%= Ecto.Changeset.fetch_field!(@form.source, @doc_desc_amount)
          |> Number.Delimit.number_to_delimited() %>
        </div>
        <div class="detail-setting-col" />
      </div>

      <div class="flex flex-row">
        <div class="w-[82%]"></div>
        <div class="w-[10%] text-right px-1">
          <%= gettext("Tax Total") %>
        </div>
        <div class="detail-amt-col text-right px-1">
          <%= Ecto.Changeset.fetch_field!(@form.source, @doc_tax_amount)
          |> Number.Delimit.number_to_delimited() %>
        </div>
        <div class="detail-setting-col" />
      </div>

      <div class="flex flex-row">
        <div class="w-[82%]"></div>
        <div class={"w-[10%] text-right px-1 border-t #{if(@matched_trans == [], do: "font-semibold border-b-4 border-double")} border-black"}>
          <%= gettext("Note Total") %>
        </div>
        <div class={"detail-amt-col text-right border-t #{if(@matched_trans == [], do: "font-semibold border-b-4 border-double")} border-black"}>
          <div>
            <%= Ecto.Changeset.fetch_field!(@form.source, @doc_detail_amount)
            |> Number.Delimit.number_to_delimited() %>
          </div>
          <.error :for={msg <- Enum.map(@form[@doc_detail_amount].errors, &translate_error(&1))}>
            <%= msg %>
          </.error>
        </div>
        <div class="detail-setting-col" />
      </div>

      <%= for obj <- @matched_trans do %>
        <div class="flex flex-row">
          <div class="w-[82%]"></div>
          <div class="w-[10%] text-right px-1">
            <.link
              class="text-red-600 hover:font-bold"
              target="_blank"
              navigate={"/companies/#{@current_company.id}/#{obj.doc_type}/#{obj.doc_id}/edit"}
            >
              <%= gettext("Less") %> <%= obj.doc_type %>
            </.link>
          </div>
          <div class="text-red-600 detail-amt-col text-right px-1">
            <%= Number.Delimit.number_to_delimited(obj.match_amount |> Decimal.abs()) %>
          </div>
          <div class="detail-setting-col" />
        </div>
      <% end %>

      <div :if={@matched_trans != []} class="flex flex-row">
        <div class="w-[82%]"></div>
        <div class="w-[10%] font-bold text-right px-1 border-t border-b-4 border-double border-black">
          <%= gettext("Balance") %>
        </div>
        <div class="detail-amt-col font-bold text-right px-1 border-t border-b-4 border-double border-black">
          <%= Decimal.add(
            Ecto.Changeset.fetch_field!(@form.source, @doc_detail_amount),
            Enum.reduce(@matched_trans, 0, fn obj, acc ->
              if(obj.doc_type == "Receipt" or obj.doc_type == "CreditNote",
                do: Decimal.add(acc, obj.match_amount),
                else: Decimal.add(acc, Decimal.negate(obj.match_amount))
              )
            end)
          )
          |> Number.Delimit.number_to_delimited() %>
        </div>
        <div class="detail-setting-col" />
      </div>
    </div>
    """
  end
end
