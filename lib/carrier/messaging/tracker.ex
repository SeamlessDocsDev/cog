defmodule Carrier.Messaging.Tracker do

  defstruct [reply_endpoints: %{}, subscriptions: %{}, monitors: %{}, unused_topics: []]

  @spec add_reply_endpoint(Tracker.t, pid()) :: {Tracker.t, String.t}
  def add_reply_endpoint(%__MODULE__{reply_endpoints: reps}=tracker, subscriber) do
    case Map.get(reps, subscriber) do
      nil ->
        topic = make_reply_endpoint_topic()
        reps = reps
        |> Map.put(subscriber, topic)
        |> Map.put(topic, subscriber)
        {maybe_monitor_subscriber(%{tracker | reply_endpoints: reps}, subscriber), topic}
      topic ->
        {tracker, topic}
    end
  end

  @spec get_reply_endpoint(Tracker.t, pid()) :: String.t | nil
  def get_reply_endpoint(%__MODULE__{reply_endpoints: reps}, subscriber) do
    Map.get(reps, subscriber)
  end

  @spec add_subscription(Tracker.t, String.t, pid()) :: Tracker.t
  def add_subscription(%__MODULE__{subscriptions: subs}=tracker, topic, subscriber) do
    subs = Map.update(subs, topic, {subscription_matcher(topic), [subscriber]},
      fn({matcher, subscribed}) -> {matcher, Enum.uniq([subscriber|subscribed])} end)
    maybe_monitor_subscriber(%{tracker | subscriptions: subs}, subscriber)
  end

  @spec del_subscription(Tracker.t, String.t, pid()) :: {Tracker.t, boolean()}
  def del_subscription(%__MODULE__{subscriptions: subs, unused_topics: ut}=tracker, topic, subscriber) do
    case Map.get(subs, topic) do
      {_matcher, [^subscriber]} ->
        subs = Map.delete(subs, topic)
        {maybe_unmonitor_subscriber(%{tracker | subscriptions: subs, unused_topics: Enum.uniq([topic|ut])}, subscriber), true}
      {matcher, subscribed} ->
        case List.delete(subscribed, subscriber) do
          ^subscribed ->
            {tracker, false}
          updated ->
            {maybe_unmonitor_subscriber(%{tracker | subscriptions: Map.put(subs, topic, {matcher, updated})}, subscriber), true}
        end
      nil ->
        {tracker, false}
    end
  end

  @spec find_reply_subscriber(Tracker.t, String.t) :: pid() | nil
  def find_reply_subscriber(%__MODULE__{reply_endpoints: reps}, topic) do
    Map.get(reps, topic)
  end

  @spec find_subscribers(Tracker.t, String.t) :: [] | [pid()]
  def find_subscribers(%__MODULE__{subscriptions: subs}, topic) do
    Enum.reduce(subs, [], &(find_matching_subscriptions(&1, topic, &2)))
  end

  @spec del_subscriber(Tracker.t, pid()) :: Tracker.t
  def del_subscriber(tracker, subscriber) do
    tracker
    |> del_reply_endpoint(subscriber)
    |> del_all_subscriptions(subscriber)
    |> unmonitor_subscriber(subscriber)
  end

  @spec unused?(Tracker.t) :: boolean()
  def unused?(%__MODULE__{reply_endpoints: reps, subscriptions: subs, monitors: monitors}) do
    Enum.empty?(reps) and Enum.empty?(subs) and Enum.empty?(monitors)
  end

  @spec get_and_reset_unused_topics(Tracker.t) :: {Tracker.t, [String.t]}
  def get_and_reset_unused_topics(tracker) do
    {%{tracker | unused_topics: []}, tracker.unused_topics}
  end

  defp make_reply_endpoint_topic() do
    id = UUID.uuid4(:hex)
    "carrier/call/reply/#{id}"
  end

  defp find_matching_subscriptions({_, {matcher, subscribed}}, topic, accum) do
    if Regex.match?(matcher, topic) do
      accum ++ subscribed
    else
      accum
    end
  end

  # Tracker users regexes to find subscribers for a given MQTT topic because
  # the MQTT standard describes two types of wildcard subscriptions:
  #   * "foo/+" means "subscribe to foo and all topics one level down"
  #   * "foo/*" means "subscribe to foo and all subtopics regardless of depth"
  defp subscription_matcher(sub_topic) do
    regex = case String.slice(sub_topic, -2, 2) do
              "/+" ->
                "^#{String.slice(sub_topic, 0, String.length(sub_topic) - 1)}[a-zA-Z0-9_\-]+$"
              "/*" ->
                "^#{String.slice(sub_topic, 0, String.length(sub_topic) - 1)}.*"
              _ ->
                "^#{sub_topic}$"
            end
    Regex.compile!(regex)
  end

  def maybe_monitor_subscriber(%__MODULE__{monitors: monitors}=tracker, subscriber) do
    case Map.get(monitors, subscriber) do
      nil ->
        mref = :erlang.monitor(:process, subscriber)
        %{tracker | monitors: Map.put(monitors, subscriber, mref)}
      _ ->
        tracker
    end
  end

  def maybe_unmonitor_subscriber(%__MODULE__{monitors: monitors}=tracker, subscriber) do
    if has_subscriptions?(tracker, subscriber) do
      tracker
    else
        {_, monitors} = Map.get_and_update(monitors, subscriber,
          fn(nil) -> :pop
            (mref) -> :erlang.demonitor(mref, [:flush])
                      :pop end)
        %{tracker | monitors: monitors}
    end
  end

  def unmonitor_subscriber(%__MODULE__{monitors: monitors}=tracker, subscriber) do
    case Map.pop(monitors, subscriber) do
      {nil, _monitors} ->
        tracker
      {mref, monitors} ->
        :erlang.demonitor(mref, [:flush])
        %{tracker | monitors: monitors}
    end
  end

  defp has_subscriptions?(tracker, subscriber) do
    Map.has_key?(tracker.reply_endpoints, subscriber) or
      Enum.any?(tracker.subscriptions, &(has_subscription?(&1, subscriber)))
  end

  defp has_subscription?({_, {_, subscribed}}, subscriber) do
    Enum.member?(subscribed, subscriber)
  end

  defp del_reply_endpoint(%__MODULE__{reply_endpoints: reps, unused_topics: ut}=tracker, subscriber) do
    case Map.get(reps, subscriber) do
      nil ->
        tracker
      rep ->
        reps = reps
        |> Map.delete(rep)
        |> Map.delete(subscriber)
        %{tracker | reply_endpoints: reps, unused_topics: Enum.uniq([rep|ut])}
    end
  end

  defp del_all_subscriptions(%__MODULE__{subscriptions: subs}=tracker, subscriber) do
    {subs, unused_topics} = Enum.reduce(Map.keys(subs), {subs, []}, &(delete_subscription(&1, subscriber, &2)))
    %{tracker | subscriptions: subs, unused_topics: tracker.unused_topics ++ unused_topics}
  end

  defp delete_subscription(topic, subscriber, {subs, unused_topics}) do
    case Map.get(subs, topic) do
      nil ->
        {subs, unused_topics}
      {_matcher, [^subscriber]} ->
        {Map.delete(subs, topic), [topic|unused_topics]}
      {matcher, subscribed} ->
        {Map.put(subs, topic, {matcher, List.delete(subscribed, subscriber)}), unused_topics}
    end
  end

end
