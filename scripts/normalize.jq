# Canonical workflow representation shared by export.sh and deploy.sh.
# Keeps only fields that define behavior; strips runtime noise (versionId,
# updatedAt, staticData, active, pinData, ...) so exports diff cleanly and
# the deploy drift-guard can compare instance state against git history.
{
  id,
  name,
  nodes,
  connections,
  settings: (.settings // {} | {
    executionOrder, timezone, callerPolicy, callerIds,
    availableInMCP, saveExecutionProgress, saveManualExecutions,
    saveDataErrorExecution, saveDataSuccessExecution,
    executionTimeout, errorWorkflow, timeSavedPerExecution
  } | with_entries(select(.value != null))),
  tags: ([(.tags // [])[] | {name}] | sort_by(.name))
}
