defmodule Rodar.Activity.Task.Service.Handler do
  @moduledoc """
  Behaviour for service task handlers.

  Implement `execute/2` to define the business logic for a service task.
  The callback receives the task element attributes and the current context data,
  and should return one of:

    * `{:ok, result_map}` — task completed successfully; the result map is merged
      into the context data and the token is released to outgoing flows.
    * `{:error, reason}` — task failed; the error propagates up.
    * `{:bpmn_error, error_code, message}` — a BPMN error occurred; if an error
      boundary event is attached to the service task, the token is routed there.
      Otherwise, the error propagates as `{:error, message}`.
    * `{:async, reference}` — the task will complete asynchronously; the process
      is suspended (returns `{:manual, _}`). Use
      `Rodar.Activity.Task.Service.complete_async/3` to resume.
  """

  @callback execute(attrs :: map(), data :: map()) ::
              {:ok, map()}
              | {:error, String.t()}
              | {:bpmn_error, String.t(), String.t()}
              | {:async, any()}
end
