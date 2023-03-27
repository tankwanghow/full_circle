defmodule FullCircleWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FullCircleWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint FullCircleWeb.Endpoint

      use FullCircleWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FullCircleWeb.ConnCase
    end
  end

  setup tags do
    FullCircle.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, user) do
    token = FullCircle.UserAccounts.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defmacro test_input_feedback(form, field, value, feedback) do
    quote do
      test "input feedback #{unquote(form)} #{unquote(field)} = #{unquote(value)}", %{
        lv: lv
      } do
        form = unquote(form)
        field = unquote(field)
        value = unquote(value)
        feedback = unquote(feedback)

        html =
          lv
          |> element("##{form}")
          |> render_change(%{form => %{field => value}})
          |> Floki.parse_document!()

        text =
          Floki.find(html, ~s|div[phx-feedback-for="#{form}[#{field}]"] span.text-red-500|)
          |> Floki.text()

        assert text =~ feedback
      end
    end
  end

  defmacro test_input_value(form, tag, :text, field) do
    quote do
      test "input value #{unquote(form)} #{unquote(field)}", %{lv: lv, obj: obj} do
        form = unquote(form)
        tag = unquote(tag)
        field = unquote(field)
        value = Map.get(obj, String.to_atom(field))

        html = render(lv)

        text =
          case tag do
            "select" ->
              Floki.find(html, ~s|#{tag}[name="#{form}[#{field}]"] option[selected]|)
              |> Floki.attribute("value")
              |> Enum.at(0)

            "textarea" ->
              Floki.find(html, ~s|#{tag}[name="#{form}[#{field}]"]|) |> Floki.text()

            _ ->
              Floki.find(html, ~s|#{tag}[name="#{form}[#{field}]"]|)
              |> Floki.attribute("value")
              |> Enum.at(0)
          end

        assert text == value
      end
    end
  end

  defmacro test_input_value(form, tag, :number, field) do
    quote do
      test "input value #{unquote(form)} #{unquote(field)}", %{lv: lv, comp: comp} do
        form = unquote(form)
        tag = unquote(tag)
        field = unquote(field)
        value = Map.get(comp, String.to_atom(field))

        html = render(lv)

        selector =
          if tag != "select" do
            ~s|#{tag}[name="#{form}[#{field}]"]|
          else
            ~s|#{tag}[name="#{form}[#{field}]"] option[selected]|
          end

        text = Floki.find(html, selector) |> Floki.attribute("value") |> Enum.at(0)

        assert (Decimal.new(text) |> Decimal.to_float()) - value == 0.0
      end
    end
  end
end
