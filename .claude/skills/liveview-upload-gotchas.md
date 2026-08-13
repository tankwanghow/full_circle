---
name: liveview-upload-gotchas
description: Use when a LiveView file upload does nothing after choosing a file — no network traffic, no progress, no error, auto_upload never starts — or when adding/reviewing an upload form or writing upload tests with render_upload. Covers the phx-change form contract for live_file_input and the LiveViewTest blind spot that keeps broken uploads green.
---

# LiveView Upload Gotchas

## 1. `live_file_input` uploads nothing without `phx-change` on its form

The browser-side upload client (including `auto_upload: true`) only activates for a file
input whose **form binds `phx-change`**. Without the binding, picking a file produces
**zero network traffic and zero errors** — the page just sits there. Nothing on the server
runs, so no log line ever appears either.

```heex
<%!-- BROKEN: file selection does nothing in a real browser --%>
<form id="bundle-upload-form">
  <.live_file_input upload={@uploads.bundle} />
</form>

<%!-- WORKING: bind phx-change (a no-op handler is fine) --%>
<form id="bundle-upload-form" phx-change="validate">
  <.live_file_input upload={@uploads.bundle} />
</form>
```

```elixir
def handle_event("validate", _params, socket), do: {:noreply, socket}
```

Working in-repo patterns: `bank_reconciliation_live/index.ex` (input inside the
`phx-change="changed"` search form), `time_attend_live/upload_punch_log.ex` and
`statutory_rate_table_live/form.ex` (`phx-change="validate"`). The statutory bundle import
page shipped without the binding and was broken in production until 796b681c.

## 2. `render_upload` in tests cannot catch a missing `phx-change`

`Phoenix.LiveViewTest.render_upload/2` drives the upload machinery server-side and skips
the browser contract above, so **upload tests stay green while the real page is dead**.
Manual browser check is the only true end-to-end proof.

Pin the contract with a DOM assertion next to the upload tests:

```elixir
test "upload form binds phx-change so the browser can start the auto-upload", %{conn: conn, com: com} do
  {:ok, lv, _html} = live(conn, ~p"/companies/#{com.id}/statutory_bundle/import")
  assert lv |> element("#bundle-upload-form") |> render() =~ "phx-change"
end
```

## Checklist for a new upload form

- [ ] `allow_upload` in mount (`auto_upload: true` + `progress:` callback if no submit step)
- [ ] file input's form has `phx-change` bound to an existing handler (no-op is fine)
- [ ] DOM assertion pinning `phx-change` on the form
- [ ] verified once in a real browser (network tab shows upload traffic on selection)
