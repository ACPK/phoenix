defmodule Phoenix.Channel.Transport do

  require Logger
  alias Phoenix.Socket
  alias Phoenix.Socket.Message


  @moduledoc """
  Handles dispatching incoming and outgoing Channel messages

  ## The Transport Adapter Contract

  The Transport layer dispatches `%Phoenix.Socket.Message{}`'s from remote clients,
  backed by different Channel transport implementations and serializations.

  ### Server

  To implement a Transport adapter, the Server must broker the following actions:

    * Handle receiving incoming, encoded `%Phoenix.Socket.Message{}`'s from
      remote clients, then deserialing and fowarding message through
      `Phoenix.Transport.dispatch/2`. Message keys must be deserialized as strings.
    * Handle receiving outgoing `{:socket_reply, %Phoenix.Socket.Message{}}` as
      Elixir process messages, then encoding and fowarding to remote client.
    * Handle receiving `{:put_socket, topic, socket_pid}` messages and storing a
      HashDict of a string topics to Pid matches. The HashDict of topic => pids
      is dispatched through the transport layer's `Phoenix.Transport.dispatch/2`.
    * Handle receiving `{:delete_socket, topic}` messages and delete the entry
      from the kept HashDict of socket processes.
    * Handle remote client disconnects and relaying event through
      `Phoenix.Transport.dispatch_leave/2`

  See `Phoenix.Transports.WebSocket` for an example transport server implementation.


  ### Remote Client

  Phoenix includes a JavaScript client for WebSocket and Longpolling support using JSON
  encodings.

  However, a client can be implemented for other protocols and encodings by
  abiding by the `Phoenix.Socket.Message` format

  See `web/static/js/phoenix.js` for an example transport client implementation.
  """

  @doc """
  Dispatches `%Phoenix.Socket.Message{}` to Channel. All serialized, remote client messages
  should be deserialized and forwarded through this function by adapters.

  The following return signatures must be handled by transport adapters:
    * `{:ok, socket_pid}` - Successful dispatch, with pid of new socket
    * `{:error, reason}` - Failed dispatch
    * `:ignore` - Unauthorized or unmatched dispatch

  """
  def dispatch(%Message{} = msg, sockets, transport_pid, router, pubsub_server, transport) do
    sockets
    |> HashDict.get(msg.topic)
    # TODO handle msg.ref when I get back to this :)
    |> dispatch(msg.topic, msg.event, msg.payload, transport_pid, router, pubsub_server, transport)
  end

  @doc """
  Dispatches `%Phoenix.Socket.Message{}` in response to a heartbeat message sent from the client.

  The Message format sent to phoenix requires the following key / values:

    * `topic` - The String value "phoenix"
    * `event` - The String value "heartbeat"
    * `payload` - An empty JSON message payload, ie {}
    * `ref` - The optional message ref for sync calls, `nil` for an async message

  The server will respond to heartbeats with the same message
  """
  def dispatch(_, "phoenix", "heartbeat", _payload, transport_pid, _router, _pubsub_server, _transport) do
    send transport_pid, {:socket_reply, %Message{topic: "phoenix", event: "heartbeat", payload: %{}}}
  end
  def dispatch(nil, topic, "join", payload, transport_pid, router, pubsub_server, transport) do
    case router.channel_for_topic(topic, transport) do
      nil     -> log_ignore(topic, router)
      channel ->
        socket = %Socket{transport_pid: transport_pid,
                  router: router,
                  pubsub_server: pubsub_server,
                  topic: topic,
                  channel: channel,
                  transport: transport}

        Phoenix.Channel.Server.start_link(socket, payload)
    end
  end
  def dispatch(nil, topic, _event, _payload, _adapter_pid, router, _pubsub_server, _transport) do
    log_ignore(topic, router)
    :ignore
  end
  def dispatch(socket_pid, _topic, event, payload, _adapter_pid, _router, _pubsub_server, _transport) do
    GenServer.cast(socket_pid, {:handle_in, event, payload})
    :ok
  end

  defp log_ignore(topic, router) do
    Logger.debug fn -> "Ignoring unmatched topic \"#{topic}\" in #{inspect(router)}" end
    :ignore
  end

  @doc """
  Whenever a remote client disconnects, the adapter must forward the event through
  this function to be dispatched as `"leave"` events on each socket channel.

  Most adapters shutdown after this dispatch as they client has disconnected
  """
  def dispatch_leave(sockets, reason) do
    Enum.each sockets, fn {_, socket_pid} ->
      GenServer.cast(socket_pid, {:handle_in, "leave", reason})
    end
  end

  @doc """
  Checks the Origin request header against the list of allowed origins
  configured on the `Phoenix.Endpoint` `:transports` config. If the Origin
  header matches the allowed origins, no Origin header was sent or no origins
  configured it will return the given `Plug.Conn`. Otherwise a 403 Forbidden
  response will be send and the connection halted.
  """
  def check_origin(conn, opts \\ []) do
    import Plug.Conn

    endpoint = Phoenix.Controller.endpoint_module(conn)
    allowed_origins = Dict.get(endpoint.config(:transports), :origins)
    origin = get_req_header(conn, "origin") |> List.first

    send = opts[:send] || &send_resp(&1)

    if origin_allowed?(origin, allowed_origins) do
      conn
    else
      resp(conn, :forbidden, "")
      |> send.()
      |> halt
    end
  end

  defp origin_allowed?(nil, _) do
    true
  end
  defp origin_allowed?(_, nil) do
    true
  end
  defp origin_allowed?(origin, allowed_origins) do
    origin = URI.parse(origin)

    Enum.any?(allowed_origins, fn allowed ->
      allowed = URI.parse(allowed)

      compare?(origin.scheme, allowed.scheme) and
      compare?(origin.port, allowed.port) and
      compare?(origin.host, allowed.host)
    end)
  end

  defp compare?(nil, _), do: true
  defp compare?(_, nil), do: true
  defp compare?(x, y),   do: x == y
end
