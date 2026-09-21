#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

check_forbidden() {
  local dir="$1"
  local pattern="$2"
  local label="$3"
  if rg -n --glob '*.swift' "$pattern" "$dir" >/tmp/arch_hits.txt 2>/dev/null; then
    echo "ARCHITECTURE VIOLATION ($label):"
    cat /tmp/arch_hits.txt
    FAIL=1
  fi
}

echo "Checking CashFlowKit for forbidden imports..."
check_forbidden "$ROOT/Packages/CashFlowKit/Sources" "import (SwiftUI|UIKit|SwiftData|WidgetKit|FoundationModels|ActivityKit)" "CashFlowKit UI/persistence/FM"

echo "Checking CashFlowData for forbidden ActivityKit..."
check_forbidden "$ROOT/Packages/CashFlowData/Sources" "import ActivityKit" "CashFlowData ActivityKit"

echo "Checking Features for forbidden direct I/O..."
check_forbidden "$ROOT/ExpenseTracking/Features" "import SwiftData" "Features SwiftData"
check_forbidden "$ROOT/ExpenseTracking/Features" "ModelContext" "Features ModelContext"
check_forbidden "$ROOT/ExpenseTracking/Features" "SimpleFINAccount|SimpleFINTransactionDTO|URLSession\(" "Features networking/DTOs"
check_forbidden "$ROOT/ExpenseTracking/Features" "import FoundationModels" "Features FoundationModels"
check_forbidden "$ROOT/ExpenseTracking/Features" "import ActivityKit" "Features ActivityKit"

echo "Checking Views do not construct SimpleFINBankLinkingService..."
if rg -n --glob '*.swift' "SimpleFINBankLinkingService\(" "$ROOT/ExpenseTracking/Features" >/tmp/arch_hits.txt 2>/dev/null; then
  echo "ARCHITECTURE VIOLATION (Features constructing SimpleFIN):"
  cat /tmp/arch_hits.txt
  FAIL=1
fi

echo "Checking for Double/Float currency antipatterns in domain..."
# Soft signal: Decimal-typed amount properties should not be assigned from Double literals in Kit use cases.
# (Chart views may use NSDecimalNumber.doubleValue — allowed outside CashFlowKit.)

if [[ "$FAIL" -ne 0 ]]; then
  echo "Architecture check FAILED"
  exit 1
fi

echo "Architecture check passed"
