defmodule Mix.Discord.Utils do
  @moduledoc false

  @logger_prefix "Mix.Discord.Utils"

  @doc """
  Starts the `:discord` application and its dependencies.
  """
  def start! do
    Discord.Log.debug(@logger_prefix, "ensuring application started")
    {:ok, _} = Application.ensure_all_started(:discord)
    :ok
  end
end
