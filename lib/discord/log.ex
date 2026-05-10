defmodule Discord.Log do
  @moduledoc false

  require Logger

  @doc """
  Logs a debug message with the given prefix and metadata.

  ## Examples

      iex> Discord.Log.debug("Gateway", "Received event")
      :ok
  """
  @spec debug(prefix :: String.t(), message :: String.t(), metadata :: keyword()) :: :ok
  def debug(prefix, message, metadata \\ []) do
    prefix
    |> format_message(message)
    |> Logger.debug(metadata)
  end

  @doc """
  Logs an info message with the given prefix and metadata.

  ## Examples

      iex> Discord.Log.info("Gateway", "Connection established")
      :ok
  """
  @spec info(prefix :: String.t(), message :: String.t(), metadata :: keyword()) :: :ok
  def info(prefix, message, metadata \\ []) do
    prefix
    |> format_message(message)
    |> Logger.info(metadata)
  end

  @doc """
  Logs a warning message with the given prefix and metadata.

  ## Examples

      iex> Discord.Log.warning("Gateway", "Connection lost")
      :ok
  """
  @spec warning(prefix :: String.t(), message :: String.t(), metadata :: keyword()) :: :ok
  def warning(prefix, message, metadata \\ []) do
    prefix
    |> format_message(message)
    |> Logger.warning(metadata)
  end

  @doc """
  Logs an error message with the given prefix and metadata.

  ## Examples

      iex> Discord.Log.error("Gateway", "Connection failed")
      :ok
  """
  @spec error(prefix :: String.t(), message :: String.t(), metadata :: keyword()) :: :ok
  def error(prefix, message, metadata \\ []) do
    prefix
    |> format_message(message)
    |> Logger.error(metadata)
  end

  defp format_message(prefix, message) do
    "[#{prefix}] #{message}"
  end
end
