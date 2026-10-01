defmodule FullCircleWeb.EInvComponents do
  @moduledoc """
  e-Invoice column for decluttered document listings: one status chip per row
  plus a per-row expander listing every candidate e-invoice with its own
  Match / Remove Match action.

  The host row LiveComponent keeps its `"match"` / `"unmatch"` event handlers
  (they call `EInvMetas.match/4` / `unmatch/3`), a boolean `@einv_open`
  defaulted in `update/2`, and a `"toggle_einv"` handler.
  """
  use Phoenix.Component
  use Gettext, backend: FullCircleWeb.Gettext

  import FullCircleWeb.ListComponents, only: [chip: 1, chip_class: 1]

  alias FullCircleWeb.Helpers

  @doc """
  Summary for the chip. `e_inv_uuid` is the document's matched UUID.

  :valid | {:problem, label} | {:match_one, einv} | {:match_many, n} | :none
  """
  def einv_state(e_inv_uuid, e_invs) do
    matched? = e_inv_uuid not in [nil, ""]
    matched = matched? && Enum.find(e_invs, &(&1.uuid == e_inv_uuid))
    valid = Enum.filter(e_invs, &(&1.status == "Valid"))

    cond do
      matched && matched.status == "Valid" -> :valid
      matched -> {:problem, matched.status}
      matched? -> {:problem, gettext("Mismatch")}
      length(valid) == 1 -> {:match_one, hd(valid)}
      valid != [] -> {:match_many, length(valid)}
      true -> :none
    end
  end

  @doc """
  The e-Invoice status chip. `:none` shows `none_label` as a link to the
  MyInvois portal; with `copy_text` it also copies the document no first.
  """
  attr :state, :any, required: true
  attr :fc, :map, required: true, doc: "the row's document map (JSON-encoded for match)"
  attr :doc_id, :string, required: true
  attr :einv_portal, :string, required: true
  attr :myself, :any, required: true
  attr :none_label, :string, required: true
  attr :copy_text, :string, default: nil

  def einv_chip(assigns) do
    ~H"""
    <%= case @state do %>
      <% :valid -> %>
        <.chip kind={:ok}>✓ {gettext("Valid")}</.chip>
      <% {:problem, label} -> %>
        <.chip kind={:bad}>⚠ {label}</.chip>
      <% {:match_one, einv} -> %>
        <.match_button fc={@fc} einv={einv} myself={@myself} />
      <% {:match_many, n} -> %>
        <button
          type="button"
          phx-click="toggle_einv"
          phx-target={@myself}
          class={["rounded-full px-2 py-0.5 text-xs font-medium", chip_class(:todo)]}
        >
          {gettext("%{n} to match", n: n)} ▸
        </button>
      <% :none -> %>
        <a
          :if={@copy_text}
          id={"einv-new-#{@doc_id}"}
          href="#"
          phx-hook="copyAndOpen"
          copy-text={@copy_text}
          goto-url={"#{@einv_portal}/newdocument"}
          class={["rounded-full px-2 py-0.5 text-xs font-medium hover:underline", chip_class(:todo)]}
          title={gettext("Copy the document no and open the MyInvois portal")}
        >
          ○ {@none_label} →
        </a>
        <a
          :if={!@copy_text}
          target="_blank"
          href={"#{@einv_portal}/newdocument"}
          class={["rounded-full px-2 py-0.5 text-xs font-medium hover:underline", chip_class(:todo)]}
        >
          ○ {@none_label} →
        </a>
    <% end %>
    """
  end

  @doc "▸ / ▾ toggle for the row's e-invoice details."
  attr :open, :boolean, required: true
  attr :myself, :any, required: true

  def einv_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_einv"
      phx-target={@myself}
      class="w-6 shrink-0 text-slate-400 hover:text-slate-700 dark:hover:text-slate-200"
      title={gettext("e-Invoice details")}
    >
      {if @open, do: "▾", else: "▸"}
    </button>
    """
  end

  @doc "Expanded details: one line per candidate e-invoice with its action."
  attr :e_invs, :list, required: true
  attr :fc, :map, required: true
  attr :doc_id, :string, required: true
  attr :copy_text, :string, default: nil
  attr :company, :map, required: true
  attr :einv_portal, :string, required: true
  attr :myself, :any, required: true

  def einv_details(assigns) do
    ~H"""
    <div class="ml-8 mr-2 mb-2 rounded border border-slate-200 dark:border-gray-700 text-xs">
      <div :if={@e_invs == []} class="p-2 text-slate-500">
        {gettext("No e-invoice found for this document.")}
      </div>
      <div
        :for={einv <- @e_invs}
        class="flex flex-wrap items-center gap-x-5 gap-y-1 p-2 border-b border-slate-200 dark:border-gray-700 last:border-0"
      >
        <a
          class="text-sky-700 dark:text-sky-400 hover:underline"
          target="_blank"
          href={"#{@einv_portal}/documents/#{einv.uuid}"}
        >
          {einv.uuid}
        </a>
        <span>
          <span class="text-slate-500">{gettext("Received")}</span>
          {einv.dateTimeReceived |> Helpers.format_datetime(@company)}
        </span>
        <span>
          <span class="text-slate-500">{gettext("Issued")}</span>
          {einv.dateTimeIssued |> Helpers.format_datetime(@company)}
        </span>
        <span :if={einv.rejectRequestDateTime}>
          <span class="text-slate-500">{gettext("Reject requested")}</span>
          {einv.rejectRequestDateTime |> Helpers.format_datetime(@company)}
        </span>
        <span>{einv.internalId} · {einv.typeName} {einv.typeVersionName}</span>
        <span class="truncate max-w-64" title={einv.buyerTIN}>{einv.buyerName}</span>
        <span class="tabular-nums">
          {einv.documentCurrency}
          {Number.Delimit.number_to_delimited(
            if Decimal.gt?(einv.totalNetAmount, einv.totalPayableAmount),
              do: einv.totalNetAmount,
              else: einv.totalPayableAmount
          )}
        </span>
        <.chip kind={if einv.status == "Valid", do: :ok, else: :bad}>{einv.status}</.chip>
        <span class="ml-auto">
          <.einv_action
            fc={@fc}
            einv={einv}
            doc_id={@doc_id}
            copy_text={@copy_text}
            einv_portal={@einv_portal}
            myself={@myself}
          />
        </span>
      </div>
    </div>
    """
  end

  attr :fc, :map, required: true
  attr :einv, :map, required: true
  attr :doc_id, :string, required: true
  attr :copy_text, :string, default: nil
  attr :einv_portal, :string, required: true
  attr :myself, :any, required: true

  defp einv_action(assigns) do
    uuid = assigns.fc[:e_inv_uuid]

    assigns =
      assign(assigns,
        kind:
          cond do
            assigns.einv.status != "Valid" -> :new
            uuid in [nil, ""] -> :match
            assigns.einv.uuid != uuid -> :wrong
            true -> :unmatch
          end
      )

    ~H"""
    <%= case @kind do %>
      <% :new -> %>
        <a
          id={"einv-new-#{@doc_id}-#{@einv.uuid}"}
          href="#"
          phx-hook="copyAndOpen"
          copy-text={@copy_text || ""}
          goto-url={"#{@einv_portal}/newdocument"}
          class="text-sky-700 dark:text-sky-400 hover:underline"
        >
          {gettext("New E-Invoice")}
        </a>
      <% :match -> %>
        <.match_button fc={@fc} einv={@einv} myself={@myself} />
      <% :wrong -> %>
        <span class="text-rose-700 dark:text-rose-300">{gettext("Wrongly matched")}</span>
      <% :unmatch -> %>
        <.link
          phx-target={@myself}
          phx-value-fcdoc={Jason.encode!(@fc)}
          phx-click="unmatch"
          class="rounded border border-rose-400/70 px-2 py-0.5 text-rose-800 dark:text-rose-300 hover:bg-rose-100/60 dark:hover:bg-rose-950"
        >
          {gettext("Remove Match")}
        </.link>
    <% end %>
    """
  end

  attr :fc, :map, required: true
  attr :einv, :map, required: true
  attr :myself, :any, required: true

  defp match_button(assigns) do
    ~H"""
    <.link
      phx-target={@myself}
      phx-value-einv={Jason.encode!(@einv)}
      phx-value-fcdoc={Jason.encode!(@fc)}
      phx-click="match"
      class={["rounded-full px-2 py-0.5 text-xs font-medium hover:underline", chip_class(:todo)]}
    >
      {gettext("Match")}
    </.link>
    """
  end
end
