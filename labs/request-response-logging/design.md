# Design Document: AI Gateway Request/Response Logging

## 1. 問題與需求

### 1.1 目標

在 Azure APIM AI Gateway 層，**統一記錄所有 LLM 請求的 input 與 output**，不需改動後端或客戶端程式碼。

### 1.2 範圍

| 項目 | 支援 |
|------|------|
| Chat Completions API (`/chat/completions`) | ✅ |
| Responses API (`/responses`) | ✅ |
| Agent Service API (`/assistants`、`/threads/{id}/runs`、`/threads/{id}/messages`) | ✅ |
| Streaming (SSE) 請求 | ✅ |
| Tool calls / Function calling 記錄 | ✅ |
| Token usage 統計 | ✅ |

### 1.3 非目標

- 不做 PII 遮罩（可作為未來擴充）
- 不做即時告警（另有 Azure Monitor Alert）
- 不改動現有 API 定義

---

## 2. 架構設計

### 2.1 整體架構

```
┌─────────────┐
│   Client    │
│ (OpenAI SDK │
│  / Agent    │
│   SDK)      │
└──────┬──────┘
       │ HTTPS
       ▼
┌─────────────────────────────────────────────────────────┐
│           APIM: testaigw01                              │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ API: /kunlenewfoundry01/openai/v1/*              │  │
│  │                                                  │  │
│  │  <inbound>                                       │  │
│  │    ├─ Built-in LLM Logging (logSettings)         │  │
│  │    ├─ Custom trace policy (補強 Agent/Streaming) │  │
│  │    └─ set-backend-service → Azure AI Foundry     │  │
│  │  </inbound>                                      │  │
│  │                                                  │  │
│  │  <outbound>                                      │  │
│  │    └─ Custom trace policy (記錄 response body)   │  │
│  │  </outbound>                                     │  │
│  └──────────────────────────────────────────────────┘  │
└────────┬───────────────────────────────┬────────────────┘
         │                               │
         │ APIM Logger (App Insights)    │ Diagnostic Setting
         │  - LLM prompts/completions    │  - GatewayLogs
         │  - Token usage                │  - Full request/response
         │  - Traces                     │
         ▼                               ▼
┌──────────────────────┐       ┌──────────────────────┐
│ Application Insights │◀──────│ Log Analytics Workspace│
│  - requests table    │       │  - ApiManagementGatewayLogs │
│  - traces table      │       │  - AzureDiagnostics  │
│  - customDimensions  │       │                      │
└──────────────────────┘       └──────────────────────┘
         │
         ▼
   KQL 查詢 / Azure Portal
```

### 2.2 雙層日誌策略

| 層級 | 機制 | 儲存位置 | 用途 |
|------|------|---------|------|
| **L1: Built-in LLM Logging** | `azureMonitor` diagnostic + `logSettings` | App Insights | 自動解析 LLM 格式（prompt/completion/tokens） |
| **L2: Custom Trace Policy** | `<trace>` + `<log-to-eventhub>`（選配） | App Insights `traces` | 補強 Agent Service、完整 body、Streaming |

---

## 3. 資源部署

### 3.1 新建資源

| 資源 | 名稱範例 | 用途 |
|------|---------|------|
| Log Analytics Workspace | `log-aigw-testing-{suffix}` | 集中儲存所有日誌 |
| Application Insights | `appi-aigw-testing-{suffix}` | LLM 格式化日誌 + Traces |
| APIM Logger (logger-id) | `appinsights-logger` | APIM → App Insights 的連接器 |
| APIM Diagnostic (`applicationinsights`) | (固定名稱) | 啟用 LLM logging + 設定 payload 大小 |

### 3.2 Bicep 設計（bicep/logging.bicep）

關鍵配置：
```bicep
resource apiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2024-05-01' = {
  name: 'applicationinsights'
  parent: api
  properties: {
    loggerId: apimLogger.id
    sampling: { samplingType: 'fixed', percentage: 100 }
    alwaysLog: 'allErrors'
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    largeLanguageModel: {
      logs: 'enabled'
      requests: {
        messages: 'all'         // 記錄所有 prompts
        maxSizeInBytes: 262144  // 256 KB
      }
      responses: {
        messages: 'all'         // 記錄所有 completions
        maxSizeInBytes: 262144
      }
    }
    frontend: {
      request: { body: { bytes: 8192 } }
      response: { body: { bytes: 8192 } }
    }
    backend: {
      request: { body: { bytes: 8192 } }
      response: { body: { bytes: 8192 } }
    }
  }
}
```

---

## 4. Policy 設計

### 4.1 LLM Logging Policy（policies/llm-logging-policy.xml）

對 OpenAI 相容 API（Chat Completions、Responses）使用，依賴 Diagnostic `largeLanguageModel` 設定自動記錄。

### 4.2 Agent Service Policy（policies/agent-logging-policy.xml）

對 Agent Service API 使用 `<trace>` 政策顯式記錄：
- Inbound：記錄 request body（instructions、messages）
- Outbound：記錄 response body（assistant reply、tool calls）
- 加上 `correlationId` metadata，方便跨請求追蹤同一 thread

Trace 會寫入 App Insights 的 `traces` 表格。

### 4.3 Streaming 支援與限制

- Built-in LLM Logging 在 2024-05 之後已支援 SSE，會把 raw SSE chunks 寫入 `Response-Body`
- `estimate-prompt-tokens="true"` 確保 inbound 估算 token

#### ⚠️ 已知限制：256KB 截斷

- `largeLanguageModel.responses.maxSizeInBytes` 上限為 **262144 bytes (256 KB)**，這是 Azure 硬限制無法調高
- Reasoning models（如 Kimi-K2.5、DeepSeek-R1）的 streaming 回應每個 chunk 都帶 `content_filter_results` 等大量 metadata，**容易超過 256KB**
- 截斷發生時，**最終的 `content`（assistant 回答）通常落在 SSE 流的末段，反而是被丟掉的部分**

#### ✅ 突破 256KB 的方案

| 方案 | 適用場景 | 實作 |
|------|---------|------|
| **A. Client 端寫 customEvents** | logging 驗證、開發測試 | Notebook section 6 已實作；用 `opencensus-ext-azure` 直接送 App Insights `AppEvents`，每 property 8KB 但可分多塊 |
| **B. log-to-eventhub policy** | Production / 大量資料 | 在 outbound 用 `<log-to-eventhub>` 把完整 body 推到 Event Hubs（單訊息 1MB），再 ingest 回 Log Analytics |
| **C. KQL 重組 raw SSE** | 已有 raw 但要分析 | `kql/queries.kql` Query #9 把 `data: {...}` chunks 拼回 `FullContent`/`FullReasoning`/`Usage`（截斷部分仍會缺） |
| **D. 改用非 streaming** | 需 100% 完整 | 對重要請求關掉 streaming，content 通常 < 10KB 可完整存下 |

---

## 5. 測試計畫

### 5.1 測試案例

| 案例 | 工具 | 驗證點 |
|------|------|------|
| TC-01 | Python OpenAI SDK | `client.chat.completions.create()` 非 streaming |
| TC-02 | Python OpenAI SDK | `client.chat.completions.create(stream=True)` |
| TC-03 | Python OpenAI SDK | `client.responses.create()` 非 streaming |
| TC-04 | Python OpenAI SDK | `client.responses.create(stream=True)` |
| TC-05 | Azure AI Agents SDK | 建立 assistant、thread、run 並驗證 |
| TC-06 | Azure AI Agents SDK | Function calling 含 tool_calls |

### 5.2 驗證方式

每個測試案例執行後：
1. 等待 30–60 秒讓日誌匯入 App Insights
2. 執行 KQL 查詢對應的 prompts/completions
3. 比對 Notebook 輸出與 Log 內容是否一致

---

## 6. KQL 查詢範例

### 6.1 查詢最近的 LLM 請求

```kusto
traces
| where timestamp > ago(1h)
| where customDimensions has "LLM"
| project timestamp, operation_Name, message, customDimensions
| order by timestamp desc
```

### 6.2 提取 prompt 與 completion

```kusto
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(1h)
| project TimeGenerated, OperationId, RequestId,
          Messages = parse_json(tostring(Properties.messages)),
          Completion = parse_json(tostring(Properties.response)),
          PromptTokens = toint(Properties.promptTokens),
          CompletionTokens = toint(Properties.completionTokens)
| order by TimeGenerated desc
```

### 6.3 統計各 API 的使用量

```kusto
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(24h)
| summarize Calls = count(),
            TotalPromptTokens = sum(toint(Properties.promptTokens)),
            TotalCompletionTokens = sum(toint(Properties.completionTokens))
        by OperationName = tostring(Properties.deploymentName)
```

---

## 7. 風險與緩解

| 風險 | 影響 | 緩解 |
|------|------|------|
| Agent Service API 格式未被 LLM Logging 原生支援 | 可能遺漏部分 Agent 請求 | 用 custom trace policy 補強 |
| Streaming 請求 body 過大超過 256KB | 被截斷 | 調高 `maxSizeInBytes` 或關閉 inbound body 記錄，改用 token metrics |
| APIM SKU 限制 | Consumption SKU 無法掛 Logger | 確認 `testaigw01` SKU；需至少 Developer/Basic |
| PII / 敏感資訊記錄 | 合規風險 | 後續用 policy 加 regex 遮罩（非本次測試範圍） |
| 日誌成本 | App Insights 收費 | 設 sampling 或 retention 限制 |

---

## 8. 後續延伸

1. **PII 遮罩** — 在 policy 中用 regex 遮罩敏感資訊後再記錄
2. **長期封存** — 透過 Diagnostic Setting 的 Export 將日誌輸出到 Storage Account
3. **結構化分析** — Event Hub + Stream Analytics → Cosmos DB（參考 `labs/message-storing`）
4. **告警** — 設定 Azure Monitor Alert 監控異常 token 使用
5. **跨 Thread 關聯** — 利用 Agent Service 的 `thread_id` 作為 correlation key


---

## 9. 雙軌日誌方案（方案 ① 與方案 ③ 並存）

### 9.1 為何要雙軌

方案 ①（APIM body logging → AppInsights）受 R1/R3/R4 三大限制；方案 ③（Foundry Diagnostic Settings → 專屬 LAW）能繞開但沒有 body。兩者**互補不取代**。

### 9.2 部署隔離設計

| 層 | 方案 ① | 方案 ③ |
|---|---|---|
| Bicep | `bicep/logging.bicep` | `bicep/foundry-diagnostics.bicep`（獨立檔） |
| 部署 script | `scripts/deploy-logging.ps1` | `scripts/deploy-foundry-diag.ps1`（含 -Destroy） |
| LAW | `log-aigw-*` | `log-foundry-diag-*`（**不同 workspace**） |
| 主表 | `AppDependencies` | `AzureDiagnostics` |
| KQL | `kql/queries.kql` | `kql/queries-foundry-diag.kql` |
| 比對 KQL | — | `kql/queries-comparison.kql`（cross-workspace） |
| Notebook | `notebooks/test-logging.ipynb` | `notebooks/test-solution3-foundry-diag.ipynb` |

可單獨部署、單獨驗證、單獨刪除，不互相干擾。

### 9.3 能力對照矩陣（已實測 + 官方文件佐證）

> ⚠️ **實測修正**：Foundry/Cognitive Services 的 `RequestResponse` log `properties_s` 只包含 `apiName` / `requestTime` / `requestLength` / `responseTime` / `responseLength` / `objectId` 6 個欄位，**不含 token 細節、不含 model deployment name**。
>
> Token 數據必須查 `AzureMetrics` 表（`InputTokens` / `OutputTokens` / `TotalTokens` / `ProcessedPromptTokens` / `GeneratedCompletionTokens`），時間粒度為 **PT1M（每分鐘聚合）**，**無法 per-request**。
>
> 官方文件：
> - [Supported log categories - Microsoft.CognitiveServices/accounts](https://learn.microsoft.com/azure/azure-monitor/reference/supported-logs/microsoft-cognitiveservices-accounts-logs)
> - [Monitoring data reference for Azure OpenAI](https://learn.microsoft.com/azure/ai-foundry/openai/monitor-openai-reference) — token metrics 列在 `Microsoft.CognitiveServices/accounts` namespace 的 platform metrics
> - [`azure-openai-emit-token-metric` policy](https://learn.microsoft.com/azure/api-management/azure-openai-emit-token-metric-policy) — 官方明示 per-request token 須由 APIM policy 從 response body parse 才能拿到

| 能力 | 方案 ① (APIM body logging) | 方案 ③ (Foundry Diagnostic) |
|---|:-:|:-:|
| 完整 prompt body | ✅ (≤256KB) | ❌ |
| 完整 completion body | ⚠️ R3 末尾截斷 | ❌ |
| **per-request** `prompt_tokens` | ⚠️ 從截斷 body 內 parse | ❌ |
| **per-request** `completion_tokens` | ⚠️ 從截斷 body 內 parse | ❌ |
| **聚合** token（per-deployment, per-minute） | ❌ | ✅ AzureMetrics |
| `requestLength` / `responseLength`（bytes） | ❌ | ✅ |
| Model deployment per-request | ✅ | ❌（只在 metric dimension） |
| `reasoning_tokens` 細項 | ⚠️ body 內 | ❌ |
| latency / status per-request | ✅ | ✅ |
| Streaming SSE 安全 | ⚠️ R4 風險 | ✅ 不經 APIM |
| API 性能影響 | 低 | 零（不在 hot path） |
| 跨 client 統一治理 | ✅ | ✅ |
| 長期保留成本 | LAW GB 計費 | LAW GB 計費（可加 Storage 歸檔） |

### 9.3.1 方案 ③ 實際適用場景

✅ **適合**：
- 計費 / 成本分析（按 deployment 聚合 token）
- SLA 監控（latency / error rate per request）
- 流量趨勢（request count / response bytes per minute）
- 安全稽核（誰、何時、從哪 IP 呼叫、status）
- 控制平面審計（`Audit` category）

❌ **不適合**：
- per-request token 用量（只能 aggregate）
- 看 prompt / completion 內容
- 取得 model deployment name per request

### 9.3.2 真正能拿 per-request token 的方案

只剩：
- **APIM `azure-openai-emit-token-metric` policy** — 官方政策，從 response body parse usage → 發成 custom metric
  - ⚠️ 對 streaming 仍要 `Body.As<string>(preserveContent:true)` → 同樣踩 R4
  - ⚠️ 開源模型（Kimi/DeepSeek）的 usage 欄位格式不一定相容
- **APIM body logging（方案 ①）** — body 內含 usage（如果沒被截）
- **Client SDK 自行記錄**（方案 B）— 可被繞過，不符治理

### 9.4 決策樹（修正版）

| 需求 | 推薦方案 |
|---|---|
| Token 計費 / SLA / 異常告警（聚合即可） | **方案 ③** 即可（最便宜、無 R4 風險） |
| 看完整 prompt/completion 內容 (≤256KB) | **方案 ①**（接受截斷風險） |
| per-request token 數據 | **方案 ① + APIM emit-token-metric policy** |
| 完整稽核 + 全文 + 計費 | **方案 ① + 方案 ③ 並存**，未來補方案 C (log-to-eventhub) |

### 9.5 驗證流程

1. 部署方案 ③：`.\scripts\deploy-foundry-diag.ps1`
2. 跑 `test-solution3-foundry-diag.ipynb` TC-07 a/b/c（每筆帶 `RUN_ID`）
3. 方案 ③ LAW 用 `queries-foundry-diag.kql` F2/F7 驗證 token
4. 方案 ① LAW 用 `queries.kql` 看 body
5. 並排比較用 `queries-comparison.kql` C1/C2/C3

---

## 10. 根因 (R1-R6) 對應官方文件

| ID | 根因 | 官方文件 |
|---|---|---|
| R1 | `maxSizeInBytes` 上限 262144 | [APIM Diagnostic ARM Schema](https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/diagnostics) / [LLM logging policies](https://learn.microsoft.com/azure/api-management/llm-logging-policies) |
| R2 | Reasoning model | [Foundry reasoning models](https://learn.microsoft.com/azure/ai-foundry/concepts/models-reasoning) |
| R3 | SSE 順序 reasoning → content | [DeepSeek-R1 reasoning_content](https://api-docs.deepseek.com/guides/reasoning_model) |
| R4 | APIM policy 讀 body 破壞 streaming | [APIM Known Issues](https://learn.microsoft.com/azure/api-management/api-management-known-issues) |
| R5 | App Insights trace 32KB / properties 8KB | [AI telemetry data model](https://learn.microsoft.com/azure/azure-monitor/app/data-model-complete) |
| R6 | Foundry concurrent quota | [Foundry quotas and limits](https://learn.microsoft.com/azure/ai-foundry/foundry-models/quotas-limits) |