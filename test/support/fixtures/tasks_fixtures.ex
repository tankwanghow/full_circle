defmodule FullCircle.TasksFixtures do
  @moduledoc false

  def task_fixture(company, user, attrs \\ %{}) do
    {:ok, task} =
      FullCircle.Tasks.create_task(Map.merge(%{"title" => "a task"}, attrs), company, user)

    task
  end
end
