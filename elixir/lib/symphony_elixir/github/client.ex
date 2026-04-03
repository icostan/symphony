defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub REST client for polling tracker issues.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @accept_header "application/vnd.github+json"
  @open_state_aliases MapSet.new(["todo", "in progress", "human review", "rework", "open"])
  @closed_state_aliases MapSet.new(["done", "closed", "canceled", "cancelled", "duplicate"])
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with {:ok, owner, repo} <- parse_repo_slug(tracker.project_slug),
         {:ok, token} <- tracker_token(tracker.api_key) do
      fetch_repo_issues(owner, repo, tracker.active_states, token)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker

    with {:ok, owner, repo} <- parse_repo_slug(tracker.project_slug),
         {:ok, token} <- tracker_token(tracker.api_key) do
      fetch_repo_issues(owner, repo, state_names, token)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    with {:ok, owner, repo} <- parse_repo_slug(tracker.project_slug),
         {:ok, token} <- tracker_token(tracker.api_key) do
      issue_ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, &reduce_issue_id(&1, &2, owner, repo, token))
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        error -> error
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with {:ok, owner, repo} <- parse_repo_slug(tracker.project_slug),
         {:ok, token} <- tracker_token(tracker.api_key),
         {:ok, issue_number} <- parse_issue_id(issue_id),
         {:ok, _response} <- post_issue_comment(owner, repo, issue_number, body, token) do
      :ok
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with {:ok, owner, repo} <- parse_repo_slug(tracker.project_slug),
         {:ok, token} <- tracker_token(tracker.api_key),
         {:ok, issue_number} <- parse_issue_id(issue_id),
         {:ok, _response} <- patch_issue_state(owner, repo, issue_number, state_name, token) do
      :ok
    end
  end

  defp fetch_repo_issues(owner, repo, state_names, token) when is_list(state_names) do
    states = normalize_issue_states(state_names)

    case states do
      [] ->
        {:ok, []}

      _ ->
        states
        |> Enum.reduce_while({:ok, []}, &reduce_state_issues(&1, &2, owner, repo, token))
        |> case do
          {:ok, issues} -> {:ok, issues |> Enum.reverse() |> Enum.uniq_by(& &1.id)}
          error -> error
        end
    end
  end

  defp list_issues(owner, repo, state, token) do
    "/repos/#{owner}/#{repo}/issues"
    |> req_get(token, params: [state: state, per_page: 100, sort: "updated", direction: "desc"])
    |> case do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub issues list failed status=#{status} body=#{inspect(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.error("GitHub issues list failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp fetch_issue(owner, repo, issue_number, token) do
    "/repos/#{owner}/#{repo}/issues/#{issue_number}"
    |> req_get(token)
    |> case do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub issue fetch failed status=#{status} body=#{inspect(body)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.error("GitHub issue fetch failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp post_issue_comment(owner, repo, issue_number, body, token) do
    req_post(
      "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments",
      token,
      %{body: body}
    )
    |> case do
      {:ok, %{status: status}} when status in [200, 201] -> {:ok, :created}
      {:ok, %{status: status, body: response_body}} -> {:error, {:github_api_status, status, response_body}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp patch_issue_state(owner, repo, issue_number, state_name, token) do
    github_state = normalize_state_name(state_name)

    req_patch(
      "/repos/#{owner}/#{repo}/issues/#{issue_number}",
      token,
      %{state: github_state}
    )
    |> case do
      {:ok, %{status: 200}} -> {:ok, :updated}
      {:ok, %{status: status, body: response_body}} -> {:error, {:github_api_status, status, response_body}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp parse_repo_slug(slug) when is_binary(slug) do
    case String.split(slug, "/", parts: 2) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, owner, repo}
      _ -> {:error, :invalid_github_project_slug}
    end
  end

  defp parse_repo_slug(_), do: {:error, :missing_github_project_slug}

  defp tracker_token(token) when is_binary(token) and token != "", do: {:ok, token}
  defp tracker_token(_), do: {:error, :missing_github_api_token}

  defp parse_issue_id(issue_id) when is_binary(issue_id) do
    case Integer.parse(issue_id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp normalize_issue_states(states) do
    states
    |> Enum.map(&normalize_state_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_state_name(state_name) when is_binary(state_name) do
    normalized = state_name |> String.trim() |> String.downcase()

    cond do
      MapSet.member?(@open_state_aliases, normalized) -> "open"
      MapSet.member?(@closed_state_aliases, normalized) -> "closed"
      true -> nil
    end
  end

  defp normalize_state_name(_), do: nil

  defp fetch_normalized_issue_by_id(owner, repo, issue_id, token) do
    with {:ok, issue_number} <- parse_issue_id(issue_id),
         {:ok, issue} <- fetch_issue(owner, repo, issue_number, token) do
      if issue_entry?(issue), do: {:ok, normalize_issue(issue)}, else: {:ok, nil}
    end
  end

  defp normalize_issue_batch(issues) do
    issues
    |> Enum.filter(&issue_entry?/1)
    |> Enum.map(&normalize_issue/1)
  end

  defp reduce_issue_id(issue_id, {:ok, acc}, owner, repo, token) do
    case fetch_normalized_issue_by_id(owner, repo, issue_id, token) do
      {:ok, nil} -> {:cont, {:ok, acc}}
      {:ok, normalized_issue} -> {:cont, {:ok, [normalized_issue | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp reduce_state_issues(state, {:ok, acc}, owner, repo, token) do
    case list_issues(owner, repo, state, token) do
      {:ok, issues} -> {:cont, {:ok, normalize_issue_batch(issues) ++ acc}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_issue(issue) when is_map(issue) do
    number = Map.get(issue, "number")
    id = if is_integer(number), do: Integer.to_string(number), else: nil

    %Issue{
      id: id,
      identifier: if(is_integer(number), do: "##{number}", else: nil),
      title: Map.get(issue, "title"),
      description: Map.get(issue, "body"),
      priority: nil,
      state: Map.get(issue, "state"),
      branch_name: nil,
      url: Map.get(issue, "html_url"),
      assignee_id: get_in(issue, ["assignee", "login"]),
      labels: normalize_labels(Map.get(issue, "labels", [])),
      assigned_to_worker: true,
      blocked_by: [],
      created_at: parse_datetime(Map.get(issue, "created_at")),
      updated_at: parse_datetime(Map.get(issue, "updated_at"))
    }
  end

  defp normalize_labels(labels) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp normalize_labels(_labels), do: []

  defp issue_entry?(%{"pull_request" => %{} = _pr}), do: false
  defp issue_entry?(%{}), do: true
  defp issue_entry?(_), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp req_get(path, token, opts \\ []) do
    Req.get(github_url(path),
      headers: github_headers(token),
      params: Keyword.get(opts, :params, [])
    )
  end

  defp req_post(path, token, json_body) do
    Req.post(github_url(path),
      headers: github_headers(token),
      json: json_body
    )
  end

  defp req_patch(path, token, json_body) do
    Req.patch(github_url(path),
      headers: github_headers(token),
      json: json_body
    )
  end

  defp github_url(path) do
    Config.settings!().tracker.endpoint <> path
  end

  defp github_headers(token) do
    [
      {"Authorization", "Bearer " <> token},
      {"Accept", @accept_header},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end
end
