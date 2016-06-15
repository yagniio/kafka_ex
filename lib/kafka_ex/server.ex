defmodule KafkaEx.Server do
  require Logger

  alias KafkaEx.Protocol, as: Proto
  @client_id                      "kafka_ex"
  @metadata_update_interval       30_000
  @consumer_group_update_interval 30_000
  @sync_timeout                   1_000
  @retry_count 3

  defmodule State do
    defstruct(metadata: %Proto.Metadata.Response{},
              brokers: [],
              event_pid: nil,
              consumer_metadata: %Proto.ConsumerMetadata.Response{},
              correlation_id: 0,
              consumer_group: nil,
              metadata_update_interval: nil,
              consumer_group_update_interval: nil,
              worker_name: KafkaEx.Server,
              sync_timeout: nil)
  end

  ### GenServer Callbacks
  use GenServer

  def start_link(args, name \\ __MODULE__)

  def start_link(args, :no_name) do
    GenServer.start_link(__MODULE__, [args])
  end

  def start_link(args, name) do
    GenServer.start_link(__MODULE__, [args, name], [name: name])
  end

  def init([args]) do
    init([args, self])
  end

  def init([args, name]) do
    uris = Keyword.get(args, :uris, [])
    metadata_update_interval = Keyword.get(args, :metadata_update_interval, @metadata_update_interval)
    consumer_group_update_interval = Keyword.get(args, :consumer_group_update_interval, @consumer_group_update_interval)

    # this should have already been validated, but it's possible someone could
    # try to short-circuit the start call
    consumer_group = Keyword.get(args, :consumer_group)
    true = KafkaEx.valid_consumer_group?(consumer_group)

    brokers = Enum.map(uris, fn({host, port}) -> %Proto.Metadata.Broker{host: host, port: port, socket: KafkaEx.NetworkClient.create_socket(host, port)} end)
    sync_timeout = Keyword.get(args, :sync_timeout, Application.get_env(:kafka_ex, :sync_timeout, @sync_timeout))
    {correlation_id, metadata} = retrieve_metadata(brokers, 0, sync_timeout)
    state = %State{metadata: metadata, brokers: brokers, correlation_id: correlation_id, consumer_group: consumer_group, metadata_update_interval: metadata_update_interval, consumer_group_update_interval: consumer_group_update_interval, worker_name: name, sync_timeout: sync_timeout}
    {:ok, _} = :timer.send_interval(state.metadata_update_interval, :update_metadata)

    # only start the consumer group update cycle if we are using consumer groups
    if consumer_group?(state) do
      {:ok, _} = :timer.send_interval(state.consumer_group_update_interval, :update_consumer_metadata)
    end

    {:ok, state}
  end

  def handle_call(:consumer_group, _from, state) do
    {:reply, state.consumer_group, state}
  end

  def handle_call({:produce, produce_request}, _from, state) do
    correlation_id = state.correlation_id + 1
    produce_request_data = Proto.Produce.create_request(correlation_id, @client_id, produce_request)
    {broker, state} = case Proto.Metadata.Response.broker_for_topic(state.metadata, state.brokers, produce_request.topic, produce_request.partition) do
      nil    ->
        {correlation_id, _} = retrieve_metadata(state.brokers, state.correlation_id, state.sync_timeout, produce_request.topic)
        state = %{update_metadata(state) | correlation_id: correlation_id}
        {Proto.Metadata.Response.broker_for_topic(state.metadata, state.brokers, produce_request.topic, produce_request.partition), state}
      broker -> {broker, state}
    end

    response = case broker do
      nil    ->
        Logger.log(:error, "Leader for topic #{produce_request.topic} is not available")
        :leader_not_available
      broker -> case produce_request.required_acks do
        0 ->  KafkaEx.NetworkClient.send_async_request(broker, produce_request_data)
        _ -> KafkaEx.NetworkClient.send_sync_request(broker, produce_request_data, state.sync_timeout) |> Proto.Produce.parse_response
      end
    end

    state = %{state | correlation_id: correlation_id + 1}
    {:reply, response, state}
  end

  def handle_call({:fetch, topic, partition, offset, wait_time, min_bytes, max_bytes, auto_commit}, _from, state) do
    true = consumer_group_if_auto_commit?(auto_commit, state)
    {response, state} = fetch(topic, partition, offset, wait_time, min_bytes, max_bytes, state, auto_commit)

    {:reply, response, state}
  end

  def handle_call({:offset, topic, partition, time}, _from, state) do
    offset_request = Proto.Offset.create_request(state.correlation_id, @client_id, topic, partition, time)
    {broker, state} = case Proto.Metadata.Response.broker_for_topic(state.metadata, state.brokers, topic, partition) do
      nil    ->
        state = update_metadata(state)
        {Proto.Metadata.Response.broker_for_topic(state.metadata, state.brokers, topic, partition), state}
      broker -> {broker, state}
    end

    {response, state} = case broker do
      nil ->
        Logger.log(:error, "Leader for topic #{topic} is not available")
        {:topic_not_found, state}
      _ ->
        response = broker
         |> KafkaEx.NetworkClient.send_sync_request(offset_request, state.sync_timeout)
         |> Proto.Offset.parse_response
        state = %{state | correlation_id: state.correlation_id + 1}
        {response, state}
    end

    {:reply, response, state}
  end

  def handle_call({:offset_fetch, offset_fetch}, _from, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)

    # if the request is for a specific consumer group, use that
    # otherwise use the worker's consumer group
    consumer_group = offset_fetch.consumer_group || state.consumer_group
    offset_fetch = %{offset_fetch | consumer_group: consumer_group}

    offset_fetch_request = Proto.OffsetFetch.create_request(state.correlation_id, @client_id, offset_fetch)

    {response, state} = case broker do
      nil    ->
        Logger.log(:error, "Coordinator for topic #{offset_fetch.topic} is not available")
        {:topic_not_found, state}
      _ ->
        response = broker
          |> KafkaEx.NetworkClient.send_sync_request(offset_fetch_request, state.sync_timeout)
          |> Proto.OffsetFetch.parse_response
        state = %{state | correlation_id: state.correlation_id + 1}
        {response, state}
    end

    {:reply, response, state}
  end

  def handle_call({:offset_commit, offset_commit_request}, _from, state) do
    {response, state} = offset_commit(state, offset_commit_request)

    {:reply, response, state}
  end

  def handle_call({:consumer_group_metadata, _consumer_group}, _from, state) do
    true = consumer_group?(state)
    {consumer_metadata, state} = update_consumer_metadata(state)
    {:reply, consumer_metadata, state}
  end

  def handle_call({:metadata, topic}, _from, state) do
    {correlation_id, metadata} = retrieve_metadata(state.brokers, state.correlation_id, state.sync_timeout, topic)
    state = %{state | metadata: metadata, correlation_id: correlation_id}
    {:reply, metadata, state}
  end

  def handle_call({:join_group, topics, session_timeout}, _from, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = Proto.JoinGroup.create_request(state.correlation_id, @client_id, "", state.consumer_group, topics, session_timeout)
    response = broker
      |> KafkaEx.NetworkClient.send_sync_request(request, state.sync_timeout)
      |> Proto.JoinGroup.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def handle_call({:sync_group, group_name, generation_id, member_id, assignments}, _from, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = Proto.SyncGroup.create_request(state.correlation_id, @client_id, group_name, generation_id, member_id, assignments)
    response = broker
      |> KafkaEx.NetworkClient.send_sync_request(request, state.sync_timeout)
      |> Proto.SyncGroup.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def handle_call({:heartbeat, group_name, generation_id, member_id}, _from, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = Proto.Heartbeat.create_request(state.correlation_id, @client_id, member_id, group_name, generation_id)
    response = broker
      |> KafkaEx.NetworkClient.send_sync_request(request, state.sync_timeout)
      |> Proto.Heartbeat.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def handle_call({:create_stream, handler, handler_init}, _from, state) do
    if state.event_pid && Process.alive?(state.event_pid) do
      info = Process.info(self)
      Logger.log(:warn, "'#{info[:registered_name]}' already streaming handler '#{handler}'")
    else
      {:ok, event_pid}  = GenEvent.start_link
      state = %{state | event_pid: event_pid}
      :ok = GenEvent.add_handler(state.event_pid, handler, handler_init)
    end
    {:reply, GenEvent.stream(state.event_pid), state}
  end

  @wait_time 900
  @min_bytes 1
  @max_bytes 1_000_000
  def handle_info({:start_streaming, _topic, _partition, _offset, _handler, _auto_commit, _poll_interval},
                  state = %State{event_pid: nil}) do
    # our streaming could have been canceled with a streaming update in-flight
    {:noreply, state}
  end
  def handle_info({:start_streaming, topic, partition, offset, handler, auto_commit, poll_interval}, state) do
    true = consumer_group_if_auto_commit?(auto_commit, state)

    {response, state} = fetch(topic, partition, offset, @wait_time, @min_bytes, @max_bytes, state, auto_commit)
    offset = case response do
               :topic_not_found ->
                 offset
               _ ->
                 message = response |> hd |> Map.get(:partitions) |> hd
                 Enum.each(message.message_set, fn(message_set) -> GenEvent.notify(state.event_pid, message_set) end)
                 case message.last_offset do
                   nil         -> offset
                   last_offset -> last_offset + 1
                 end
             end


    Process.send_after(self, {:start_streaming, topic, partition, offset, handler, auto_commit},  poll_interval)

    {:noreply, state}
  end

  def handle_info(:stop_streaming, state) do
    Logger.log(:debug, "Stopped worker #{inspect state.worker_name} from streaming")
    GenEvent.stop(state.event_pid)
    {:noreply, %{state | event_pid: nil}}
  end

  def handle_info(:update_metadata, state) do
    {:noreply, update_metadata(state)}
  end

  def handle_info(:update_consumer_metadata, state) do
    true = consumer_group?(state)
    {_, state} = update_consumer_metadata(state)
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def terminate(_, state) do
    Logger.log(:debug, "Shutting down worker #{inspect state.worker_name}")
    if state.event_pid do
      GenEvent.stop(state.event_pid)
    end
    Enum.each(state.brokers, fn(broker) -> KafkaEx.NetworkClient.close_socket(broker.socket) end)
  end

  defp update_consumer_metadata(state), do: update_consumer_metadata(state, @retry_count, 0)

  defp update_consumer_metadata(state = %State{consumer_group: consumer_group}, 0, error_code) do
    Logger.log(:error, "Fetching consumer_group #{consumer_group} metadata failed with error_code #{inspect error_code}")
    {%Proto.ConsumerMetadata.Response{error_code: error_code}, state}
  end

  defp update_consumer_metadata(state = %State{consumer_group: consumer_group, correlation_id: correlation_id}, retry, _error_code) do
    response = correlation_id
      |> Proto.ConsumerMetadata.create_request(@client_id, consumer_group)
      |> first_broker_response(state)
      |> Proto.ConsumerMetadata.parse_response

    case response.error_code do
      :no_error -> {response, %{state | consumer_metadata: response, correlation_id: state.correlation_id + 1}}
      _ -> :timer.sleep(400)
        update_consumer_metadata(%{state | correlation_id: state.correlation_id + 1}, retry - 1, response.error_code)
    end
  end

  defp update_metadata(state) do
    {correlation_id, metadata} = retrieve_metadata(state.brokers, state.correlation_id, state.sync_timeout)
    metadata_brokers = metadata.brokers
    brokers = state.brokers
      |> remove_stale_brokers(metadata_brokers)
      |> add_new_brokers(metadata_brokers)
    %{state | metadata: metadata, brokers: brokers, correlation_id: correlation_id + 1}
  end

  defp remove_stale_brokers(brokers, metadata_brokers) do
    {brokers_to_keep, brokers_to_remove} = Enum.partition(brokers, fn(broker) ->
      Enum.find_value(metadata_brokers, &(broker.host == &1.host && broker.port == &1.port && broker.socket && Port.info(broker.socket)))
    end)
    case length(brokers_to_keep) do
      0 -> brokers_to_remove
      _ -> Enum.each(brokers_to_remove, fn(broker) ->
        Logger.log(:info, "Closing connection to broker #{inspect broker.host} on port #{inspect broker.port}")
        KafkaEx.NetworkClient.close_socket(broker.socket)
      end)
        brokers_to_keep
    end
  end

  defp add_new_brokers(brokers, []), do: brokers

  defp add_new_brokers(brokers, [metadata_broker|metadata_brokers]) do
    case Enum.find(brokers, &(metadata_broker.host == &1.host && metadata_broker.port == &1.port)) do
      nil -> Logger.log(:info, "Establishing connection to broker #{inspect metadata_broker.host} on port #{inspect metadata_broker.port}")
        add_new_brokers([%{metadata_broker | socket: KafkaEx.NetworkClient.create_socket(metadata_broker.host, metadata_broker.port)} | brokers], metadata_brokers)
      _ -> add_new_brokers(brokers, metadata_brokers)
    end
  end

  defp retrieve_metadata(brokers, correlation_id, sync_timeout, topic \\ []), do: retrieve_metadata(brokers, correlation_id, sync_timeout, topic, @retry_count, 0)

  defp retrieve_metadata(_, correlation_id, _sync_timeout, topic, 0, error_code) do
    Logger.log(:error, "Metadata request for topic #{inspect topic} failed with error_code #{inspect error_code}")
    {correlation_id, %Proto.Metadata.Response{}}
  end

  defp retrieve_metadata(brokers, correlation_id, sync_timeout, topic, retry, _error_code) do
    metadata_request = Proto.Metadata.create_request(correlation_id, @client_id, topic)
    data = first_broker_response(metadata_request, brokers, sync_timeout)
    response = case data do
                 nil ->
                   Logger.log(:error, "Unable to fetch metadata from any brokers.  Timeout is #{sync_timeout}.")
                   raise "Unable to fetch metadata from any brokers.  Timeout is #{sync_timeout}."
                   :no_metadata_available
                 data ->
                   Proto.Metadata.parse_response(data)
               end

               case Enum.find(response.topic_metadatas, &(&1.error_code == :leader_not_available)) do
      nil  -> {correlation_id + 1, response}
      topic_metadata ->
        :timer.sleep(300)
        retrieve_metadata(brokers, correlation_id + 1, sync_timeout, topic, retry - 1, topic_metadata.error_code)
    end
  end

  defp fetch(topic, partition, offset, wait_time, min_bytes, max_bytes, state, auto_commit) do
    true = consumer_group_if_auto_commit?(auto_commit, state)
    fetch_request = Proto.Fetch.create_request(state.correlation_id, @client_id, topic, partition, offset, wait_time, min_bytes, max_bytes)
    {broker, state} = case Proto.Metadata.Response.broker_for_topic(state.metadata, state.brokers, topic, partition) do
      nil    ->
        state = update_metadata(state)
        {Proto.Metadata.Response.broker_for_topic(state.metadata, state.brokers, topic, partition), state}
      broker -> {broker, state}
    end

    case broker do
      nil ->
        Logger.log(:error, "Leader for topic #{topic} is not available")
        {:topic_not_found, state}
      _ ->
        response = broker
          |> KafkaEx.NetworkClient.send_sync_request(fetch_request, state.sync_timeout)
          |> Proto.Fetch.parse_response
        state = %{state | correlation_id: state.correlation_id + 1}
        case auto_commit do
          true ->
            last_offset = response |> hd |> Map.get(:partitions) |> hd |> Map.get(:last_offset)
            case last_offset do
              nil -> {response, state}
              _ ->
                offset_commit_request = %Proto.OffsetCommit.Request{
                  topic: topic,
                  offset: last_offset,
                  partition: partition,
                  consumer_group: state.consumer_group}
                {_, state} = offset_commit(state, offset_commit_request)
                {response, state}
            end
          _    -> {response, state}
        end
    end
  end

  defp offset_commit(state, offset_commit_request) do
    {broker, state} = broker_for_consumer_group_with_update(state, true)

    # if the request has a specific consumer group, use that
    # otherwise use the worker's consumer group
    consumer_group = offset_commit_request.consumer_group || state.consumer_group
    offset_commit_request = %{offset_commit_request | consumer_group: consumer_group}

    offset_commit_request_payload = Proto.OffsetCommit.create_request(state.correlation_id, @client_id, offset_commit_request)
    response = broker
      |> KafkaEx.NetworkClient.send_sync_request(offset_commit_request_payload, state.sync_timeout)
      |> Proto.OffsetCommit.parse_response

    {response, %{state | correlation_id: state.correlation_id + 1}}
  end

  defp consumer_group_if_auto_commit?(true, state) do
    consumer_group?(state)
  end
  defp consumer_group_if_auto_commit?(false, _state) do
    true
  end

  # note within the genserver state, we've already validated the
  # consumer group, so it can only be either :no_consumer_group or a
  # valid binary consumer group name
  defp consumer_group?(%State{consumer_group: :no_consumer_group}), do: false
  defp consumer_group?(_), do: true

  defp broker_for_consumer_group(state) do
    Proto.ConsumerMetadata.Response.broker_for_consumer_group(state.brokers, state.consumer_metadata)
  end

  # refactored from two versions, one that used the first broker as valid answer, hence
  # the optional extra flag to do that. Wraps broker_for_consumer_group with an update
  # call if no broker was found.
  defp broker_for_consumer_group_with_update(state, use_first_as_default \\ false) do
    case broker_for_consumer_group(state) do
      nil ->
        {_, state} = update_consumer_metadata(state)
        default_broker = if use_first_as_default, do: hd(state.brokers), else: nil
        {broker_for_consumer_group(state) || default_broker, state}
      broker ->
        {broker, state}
    end
  end

  defp first_broker_response(request, state) do
    first_broker_response(request, state.brokers, state.sync_timeout)
  end
  defp first_broker_response(request, brokers, sync_timeout) do
    Enum.find_value(brokers, fn(broker) ->
      if Proto.Metadata.Broker.connected?(broker) do
        KafkaEx.NetworkClient.send_sync_request(broker, request, sync_timeout)
      end
    end)
  end
end
