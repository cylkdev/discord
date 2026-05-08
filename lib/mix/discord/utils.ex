defmodule Mix.Discord.Utils do
  @moduledoc false

  @doc """
  Starts the `:discord` application and its dependencies.
  """
  def start! do
    {:ok, _} = Application.ensure_all_started(:discord)
    :ok
  end
end
