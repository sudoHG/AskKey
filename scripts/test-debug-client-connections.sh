#!/bin/sh
set -eu

available_kib=$(df -Pk /System/Volumes/Data | awk 'NR == 2 { print $4 }')
minimum_kib=$((80 * 1024 * 1024))
if [ "$available_kib" -lt "$minimum_kib" ]; then
  echo "Need at least 80 GiB free on /System/Volumes/Data" >&2
  exit 1
fi

swift test --filter '(CodexCLIContractTests|CodexConnectionLifecycleTests|CodexTOMLValidationTests)/'
swift test --filter '(CursorConfigSafetyTests|CursorBackupRollbackTests|CursorConnectionProtocolTests|CursorHomeIsolationTests)/'
swift test --filter '(GrokCLIConfigurationTests|GrokCLIProcessLifecycleTests|GrokCLIConnectionTests)/'
swift test --filter '(AgentClientConnectorTests|AgentClientConnectionPolicyTests|AgentApprovalPrivacyTests|AgentClientConnectionExecutionTests|CredentialEditorComponentTests|AgentClientConnectionRecoveryTests|AgentClientConfigurationPresenceTests)/'
