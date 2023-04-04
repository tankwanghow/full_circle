defmodule FullCircle.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FullCircle.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias FullCircle.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import FullCircle.DataCase
    end
  end

  setup tags do
    FullCircle.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(FullCircle.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defmacro test_not_authorise_to(action, roles) when is_list(roles) do
    quote do
      test "#{Enum.join(unquote(roles), ", ")} is NOT allow to #{unquote(action)}", %{
        company: company,
        admin: admin
      } do
        roles = unquote(roles)
        action = unquote(action)

        Enum.each(roles, fn r ->
          user = FullCircle.UserAccountsFixtures.user_fixture()
          FullCircle.Sys.allow_user_to_access(company, user, r, admin)

          assert FullCircle.Authorization.can?(user, action, company) == false,
                 "#{r} shouldn't be allowed to #{action}"
        end)

        FullCircle.Authorization.roles()
        |> Enum.reject(fn x -> Enum.find(roles, fn q -> q == x end) end)
        |> Enum.each(fn r ->
          user = FullCircle.UserAccountsFixtures.user_fixture()
          FullCircle.Sys.allow_user_to_access(company, user, r, admin)

          assert FullCircle.Authorization.can?(user, action, company) == true,
                 "#{r} should be allowed to #{action}"
        end)
      end
    end
  end

  defmacro test_authorise_to(action, roles) when is_list(roles) do
    quote do
      test "#{Enum.join(unquote(roles), ", ")} is allow to #{unquote(action)}", %{
        company: company,
        admin: admin
      } do
        roles = unquote(roles)
        action = unquote(action)

        Enum.each(roles, fn r ->
          user = FullCircle.UserAccountsFixtures.user_fixture()
          FullCircle.Sys.allow_user_to_access(company, user, r, admin)

          assert FullCircle.Authorization.can?(user, action, company) == true,
                 "#{r} should be allowed to #{action}"
        end)

        FullCircle.Authorization.roles()
        |> Enum.reject(fn x -> Enum.find(roles, fn q -> q == x end) end)
        |> Enum.each(fn r ->
          user = FullCircle.UserAccountsFixtures.user_fixture()
          FullCircle.Sys.allow_user_to_access(company, user, r, admin)

          assert FullCircle.Authorization.can?(user, action, company) == false,
                 "#{r} should't be allowed to #{action}"
        end)
      end
    end
  end
end
