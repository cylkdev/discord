defmodule Discord.Config do
  @moduledoc """
  Configuration helper for Discord application.
  """

  @app :discord

  def server_enabled? do
    Application.get_env(@app, :server_enabled) || false
  end
end
