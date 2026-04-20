# AI Gateway Request/Response Logging — 方案總覽

本文件梳理在 APIM AI Gateway 層完整記錄 LLM **input/output 內容**（不只 token 數）所探討、實作與驗證過的所有方案，包含取捨、限制與血淚教訓。

---

## TL;DR — 方案最終結論

中央稽核情境下，三個方案**三選一**部署（不會多軌並行；一般不會要求 client 端去寫不同的 header）。**新發現方案 1B 是現在的首選**，因 V1 實測證明它能**完整重組 streaming SSE**，可同時取代我們最早的方案 1 與多數方案 2 場景。

| # | 方案 | 適用 |
|---|---|---|
| 1A | APIM Built-in LLM Logging（**App Insights** logger）→ `dependencies` table | （**legacy / 不再建議**）保留原因：歷史資料、現有 Workbook；body ≤ 256KB；streaming 只記首封包 |
| **1B** | APIM Built-in LLM Logging（**Azure Monitor** logger）→ LAW `ApiManagementGatewayLlmLog` 表 | ⭐ **大多數中央稽核情境的首選**。原生 chunk + `SequenceNumber` 重組、原生 `IsStreamCompletion`、單筆 message 上限 **2 MB**、**streaming SSE 自動重組為完整 assistant content**（V1 已實測）；零 policy code |
| 2 | APIM `log-to-eventhub` → Event Hub → Blob Capture (Avro) | 任一條件成立才需要：單條 message 可能 > 2 MB、需離開 LAW（直進 ADX/Synapse）、需 > LAW 最大 retention（永久 Blob 歸檔）、或需自訂 sink 與 schema |

> 本 lab 為了能在同一座 APIM / 同一個 API 上同時驗證、A/B 比對方案 2，把方案 2 policy 設計成 **header-keyed**（只在 `X-Logging-Channel: solution-c` 時觸發）；這只是 POC 上的便利性，**正式部署不需要 client 帶任何特殊 header**——直接套用 always-on 變體即可（見 [客戶部署選項](#客戶部署選項-solution-c-變體)）。

---

## 方案 1A — APIM Built-in LLM Logging → App Insights（legacy）

### 機制

APIM API 層 Diagnostic 設定 `largeLanguageModel` block，由 APIM 自動：
1. 攔截 `chat/completions` / `responses` / agent endpoints 的 request body 與 response body
2. 透過綁定的 App Insights Logger 寫入 `dependencies` table（`type = "LLMRequest"` 或 `"LLMResponse"`）
3. 同時將 token usage 寫到 `customMetrics`

### Policy 片段（`policies/llm-logging-policy.xml`）

```xml
<llm-emit-token-metric namespace="llm-logging">
  <dimension name="Subscription ID" .../>
  <dimension name="Correlation ID" .../>
</llm-emit-token-metric>
```

API Diagnostic 設定（透過 ARM/Bicep）：

```jsonc
{
  "alwaysLog": "allErrors",
  "loggerId": "<app-insights-logger>",
  "largeLanguageModel": {
    "logs": {
      "messages": { "maxSizeInBytes": 262144 },  // 256KB hard cap
      "requests": { "maxSizeInBytes": 262144 }
    }
  }
}
```

### 優點

- **零客戶端改動**、零 policy 程式碼
- 內建 token 統計 metric，可直接用 KQL 計算成本
- 內建 PII 過濾鉤（未啟用，可後續開）
- 與 App Insights / Workbook / Alert 原生整合

### 限制（驅使方案 1B / 方案 2 出現的原因）

| # | 限制 | 影響 |
|---|---|---|
| **R1** | **單筆 message 上限 256KB**（見下方詳細說明） | 大 prompt / 長 reasoning / 完整文件分析會被截斷 |
| **R2** | App Insights 採樣 / ingestion 延遲（~2 min） | 不適合即時稽核 |
| **R3** | App Insights retention 預設 90 天 | 長期歸檔需另外搬 |
| **R4** | **Streaming（SSE）僅記錄首封包** | TC-C3 場景下 reasoning content 完全看不到（V1 實測 1A 路徑只有 ~200 bytes） |
| **R5** | 無法選擇性開關 — 全部 API / 全部請求都會寫 | 高流量成本壓力 |

> **R1、R4 已被方案 1B（GatewayLlmLogs）解決**：原生 chunk + SequenceNumber 把單筆 cap 提到 2 MB；streaming SSE 在 logger 端被自動重組為完整 assistant message。所以**新部署直接選方案 1B**；方案 1A 只剩下「歷史資料 / 既有 Workbook 鎖定 App Insights」的場景。

#### R1 為什麼是 256KB？— APIM 上限剛好對齊 Log Analytics dynamic 欄位上限

APIM Built-in LLM Logging 的 256KB 上限**不是任意挑的**，而是為了**剛好塞進 Log Analytics 一筆 record 的 `dynamic` 欄位**。整條鏈的 cap 如下：

| 層 | 設定 / 限制 | 數值 | 來源 |
|---|---|---|---|
| **(a) Log Analytics workspace 欄位上限** ⭐ 真正的瓶頸 | 每筆 record 中 `dynamic` 欄位（JSON 型，如 `customDimensions` / 自訂 schema）最大值 | **256 KB** per dynamic column | [Azure Monitor Logs — Field, record and table limits](https://learn.microsoft.com/azure/azure-monitor/logs/logs-fields#limits)；同表 `string` 欄位上限 32 KB；單筆 record 全部欄位合計 1 MB |
| **(b) APIM Diagnostic schema** | `largeLanguageModel.logs.messages.maxSizeInBytes` 與 `requests.maxSizeInBytes` 的 default 與 schema 最大允許值 | **262144 bytes (256 KB)** per message | [Microsoft.ApiManagement/service/diagnostics ARM schema](https://learn.microsoft.com/azure/templates/microsoft.apimanagement/service/apis/diagnostics) — APIM team **刻意選 262144 對齊 LAW dynamic 欄位上限**，超過此值 ARM 直接拒收 |
| **(c) 一般 APIM HTTP body diagnostic** | `frontend.request.body.bytes` / `backend.request.body.bytes` | 8192 bytes (8 KB) | 一般 HTTP diagnostic 的 body 上限只有 8KB；LLM block 是 AI gateway 特例放寬到 256KB（仍受 (a) 約束） |

> **本 lab 的 bicep 已將 (b) 設到上限 `262144`**（[`design.md` L113](./design.md)：`maxSizeInBytes: 262144  // 256 KB`），所以 256KB 是**實際拿得到、且能完整落到 LAW 的最大值**。
>
> 換句話說：(a) 才是真正的天花板；APIM (b) 的 schema 只是被動配合 (a) 的硬限制。即使未來 APIM 放寬 (b)，沒先打破 LAW (a) 也用不到。

額外效應放大「256KB 不夠」的痛點：

1. **「一筆 message」是 prompt 與 completion 各自獨立計算**，不是兩者加總。但長 reasoning / 長文件 prompt 任一邊就可能 > 256KB（GPT-4o `max_tokens=4096` 的 markdown 表格輸出常 ~120KB；Kimi-K2.5 reasoning trace 動輒 > 300KB）。
2. **Streaming（R4）讓 256KB 形同虛設**：APIM 是在 `<outbound>` 完成時才把 response body 餵給 logger，但 SSE 是 chunked transfer，APIM 只看得到首個封包（往往只有幾百 bytes 的 `chunk = { choices: [{delta: {role: "assistant"}}] }`），後續 delta 完全沒被記錄。實測 332KB streaming 完整對話進到 App Insights 只有 ~200 bytes。
3. **無法調高**：(a) 是 Log Analytics 平台級硬限制（不是 quota，無法開 ticket 提升），(b) 自然也跟著鎖死。要破這個牆**必須**換 sink（即方案 2：log-to-eventhub → Event Hub Standard 1MB / message → Blob 無上限）。

→ 凡是預期 prompt 或 completion **可能** > 256KB、或使用 streaming reasoning model，請直接走方案 2。

### 驗證

`labs/request-response-logging/notebooks/test-logging.ipynb` — 跑 5 個 TC，KQL 查詢結果寫在 cell output。

---

## 方案 1B ⭐ — APIM Built-in LLM Logging → LAW `ApiManagementGatewayLlmLog`

### 機制

APIM **API-level Diagnostic** 改用 **`azuremonitor` logger**（不是 `applicationinsights`），LLM logs 走 APIM Resource Log → LAW 專屬表 `ApiManagementGatewayLlmLog`（dedicated mode）或 `AzureDiagnostics where Category=="GatewayLlmLogs"`（legacy mode）。

```
Client → APIM API (azuremonitor diagnostic, largeLanguageModel.logs=enabled)
                ↓
        APIM Resource Log: GatewayLlmLogs
                ↓
        Diagnostic Settings → Log Analytics Workspace
                ↓
        ApiManagementGatewayLlmLog table（多筆 row：seq=0 metadata, seq=1 request, seq≥2 response chunks）
                ↓
        KQL 用 CorrelationId + SequenceNumber 重組
```

### 啟用步驟（3 步）

1. **Service-level Diagnostic Setting**（已存在的 `apim-to-log-analytics` 已涵蓋；建議切到 **Resource specific (Dedicated) destination type**，不要用 AzureDiagnostics legacy mode）：
   ```bash
   az monitor diagnostic-settings create \
     --name apim-to-law \
     --resource <APIM_RESOURCE_ID> \
     --workspace <LAW_RESOURCE_ID> \
     --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
     --export-to-resource-specific true
   ```

2. **API-level Diagnostic**（每個要記錄的 API 設一次）：
   ```bash
   az rest --method put \
     --uri "https://management.azure.com/<APIM_ID>/apis/<API_ID>/diagnostics/azuremonitor?api-version=2024-05-01" \
     --body '{"properties":{"loggerId":"<APIM_ID>/loggers/azuremonitor","alwaysLog":"allErrors","logClientIp":true,"verbosity":"information","largeLanguageModel":{"logs":"enabled","requests":{"messages":"all","maxSizeInBytes":32768},"responses":{"messages":"all","maxSizeInBytes":32768}}}}'
   ```
   `azuremonitor` logger 不需事先建立，APIM 預設就有。

3. **Portal 等價路徑**（同事截圖看到的就是這個）：API > Settings > **Azure Monitor** tab → "Log LLM messages: Enabled" → 勾 Log prompts 與 Log completions，各設大小（如 32768 bytes）。

### 容量規格（vs 方案 1A）

| 項目 | 方案 1A | **方案 1B** | 來源 |
|---|---|---|---|
| 單筆 entry 上限 | 256 KB | 32 KB（dedicated mode 自動 split） | [Set up logging for LLM APIs](https://learn.microsoft.com/azure/api-management/api-management-howto-llm-logs) |
| 跨筆重組 | 無 | ✅ `CorrelationId` + `SequenceNumber` | 同上 |
| **單條 message 全長硬上限** | 256 KB | **2 MB per request、2 MB per response** | 同上："Request messages and response messages can't exceed 2 MB each" |
| Streaming SSE | 只首封包（R4） | ✅ **完整重組為 assistant message** | V1 實測（見下） |
| Token usage 欄位 | App Insights customMetrics | 表內原生 `PromptTokens` / `CompletionTokens` / `TotalTokens` 欄位 | Schema |
| Stream 標記 | 無 | 表內 `IsStreamCompletion` bool 欄位 | Schema |
| Model / Deployment | 散在 customDimensions | 表內 `ModelName` / `DeploymentName` 欄位 | Schema |
| Sink | App Insights `dependencies.customDimensions` | LAW 專屬表 | — |
| Retention | App Insights 預設 90 天 | LAW 預設 30 天，可調至 730 天 | LAW 設定 |

### V1 驗證結果（2026-04-20，testaigw01 / kunlenewfoundry01）

設置：把 `azuremonitor` diagnostic 加到 `kunlenewfoundry01` API（`maxSizeInBytes=32768`），跑兩個請求，等 ~3 分鐘 ingest，查 LAW。

| 場景 | CorrelationId | rows | SequenceNumber 分布 | isStream | completion tokens | response 內容驗證 |
|---|---|---|---|---|---|---|
| **V1A 失敗 case**（429 從 Foundry concurrent capacity） | `8a73...b964` | 2 | 0 (metadata) + 1 (request) | false | 0 | 失敗時無 response row，但 request 已記 |
| **V1A2 大 non-streaming**（5031-byte response） | `75f8...ee79` | 4 | 0 + 1 + **2 (15000 chars) + 3 (2486 chars)** | false | 3500 | ✅ **chunking 成功**：seq 2 被截在中文 `\u` escape 中段，seq 3 從中間接續、結尾 `}` 完整。重組後 17486 chars 為完整 JSON message |
| **V1B Streaming SSE**（583,931-byte raw SSE） | `38d3...7623` | 3 | 0 + 1 + 2 (3966 chars) | **true** | 3000 | ✅ **streaming 完整重組**：seq 2 內容是 `{"role":"assistant","content":" Azure SQL ... ## Application Gateway ... Regional Load Balancer"}`，是 APIM 在 logger 端把 SSE delta 串起來後寫入的完整 assistant message。3000 token Chinese 約 4000 chars，吻合 |

> **關鍵發現**：raw SSE 583 KB 看起來嚇人，但其中 ~98% 是每 token 都重複的 `data: {"choices":[{"delta":{...}}]}\n\n` SSE wrapper；APIM logger 在 outbound 端**已經自動把 delta 拼回 assistant content**才寫入 `responseMessages`，所以 LAW 拿到的是去除 SSE 框架後的乾淨對話。這跟 1A 路徑的行為完全不同，是 GatewayLlmLogs 最有價值的差異。

### KQL 重組範例（dedicated mode）

```kusto
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(1h)
| extend ReqJson  = tostring(RequestMessages),
         RespJson = tostring(ResponseMessages)
| summarize
    Model         = anyif(ModelName, isnotempty(ModelName)),
    IsStream      = anyif(IsStreamCompletion, isnotnull(IsStreamCompletion)),
    PromptTokens  = anyif(PromptTokens, PromptTokens > 0),
    CompletionTok = anyif(CompletionTokens, CompletionTokens > 0),
    Request       = strcat_array(make_list(ReqJson),  ""),
    Response      = strcat_array(make_list(RespJson), "")
  by CorrelationId
| project CorrelationId, Model, IsStream, PromptTokens, CompletionTok,
          ReqLen=strlen(Request), RespLen=strlen(Response), Request, Response
```

### 限制 / 注意事項

| # | 項目 | 說明 |
|---|---|---|
| **G1** | 單條 message 硬上限 **2 MB** | 比 1A 的 256 KB 大 8 倍；99% LLM 對話都夠用。超過時溢位部分被丟棄（不報錯） |
| **G2** | LAW 計費按 ingested GB | chunk 多 → row 數多，但因為 logger 端已去除 SSE wrapper，實際 ingest bytes 比 raw SSE 小 ~50× |
| **G3** | Diagnostic Settings 必須選 **Resource specific (Dedicated)** destination type | 才會落到 `ApiManagementGatewayLlmLog`；legacy `AzureDiagnostics` mode 也能用，但欄位都是 `_s` 後綴、且 string 欄位被截在 ~15000 chars 而不是 32 KB（V1 實測） |
| **G4** | Retry 行為 | APIM `<retry>` 每個 attempt 產一組獨立 CorrelationId（V1 觀察到 V1A 一筆失敗的 8a73 與 V1A2 成功的 75f8 是不同 CorrelationId） |
| **G5** | API-level diagnostic 必須**額外**設 `azuremonitor` 一份 | 跟現有 `applicationinsights` diagnostic 共存（不衝突）。若客戶選定 1B，可移除 `applicationinsights` diagnostic 與 logger 以省 App Insights 成本 |

### 端到端驗證 notebook

`notebooks/test-solution-1b-llmlogs.ipynb` — 自動化驗證 4 個 TC：

| TC | 場景 | KQL 驗證重點 |
|---|---|---|
| TC-1B-1 | 短 non-streaming | 1 個 CorrelationId、3 筆 row、isStream=false、completion 內容非空 |
| TC-1B-2 | 大 non-streaming（>3500 token 中文長文） | response 被切成 ≥2 個 seq≥2 chunk、重組後長度合理 |
| TC-1B-3 | streaming SSE（Kimi-K2.5 reasoning） | **isStream=true 且 response 被 logger 自動重組為乾淨 assistant message**（1A 在這裡只能拿到 ~200 bytes） |
| TC-1B-4 | 對照組（marker 不存在） | KQL 應拿到 not found，證明驗證腳本不會誤報 |

每個 TC 後面跟一個 `verify_marker_1b()` cell，會輪詢 LAW、用 KQL 撈出 marker 對應的所有 row、檢查 SequenceNumber 連續性、重組 request + response、印出完整性報告。

---

## 方案 2— APIM `log-to-eventhub` → Event Hub → Blob Capture (Avro)

### 機制

```
Client (帶 X-Logging-Channel: solution-c)
  │
  ▼
APIM testaigw01 (combined-llm-and-eventhub-policy.xml)
  ├─ <inbound>  : 方案 1 照舊（trace + emit-token-metric）
  │              + 若 header 命中 → 抓 request body 到 variable
  ├─ <backend>  : <retry> 處理 429/5xx
  └─ <outbound> : 方案 1 照舊
                 + 若 header 命中 → 抓 response body 到 variable
                                  → log-to-eventhub × N
                                    （1 個 summary + chunkTotal × {request,response} chunks）
                                    → Event Hub: aigw-llm-logs (4 partitions, MSI auth)
                                      → Capture (60s/10MB) → Blob: capture/.../*.avro
                                        → 由 notebook 拉回比對
```

### Bicep（`bicep/eventhub-logging.bicep`）

- Event Hub Namespace `ehns-aigw-c-<suffix>` (Standard, MSI auth from APIM)
- Hub `aigw-llm-logs` (4 partitions, retention 1 day; Capture every 60s / 10MB → Storage)
- Storage Account `staigwcsv4iclcsscccc` (Standard_LRS, container `capture`)
- APIM Logger 綁 EH，user-assigned MI 已授 `Azure Event Hubs Data Sender` on Hub

### Policy 設計（`policies/combined-llm-and-eventhub-policy.xml`）

**只在 `X-Logging-Channel: solution-c` 時觸發**（header isolation）：

```xml
<choose>
  <when condition="@(context.Request.Headers...['X-Logging-Channel'] == 'solution-c')">
    <set-variable name="solc-enabled" value="true" />
    <set-variable name="solc-correlation-id"
                  value="@(... X-Run-Id 或 context.RequestId)" />
    <set-variable name="solc-request-body" value="@{ ... preserveContent=true ... }" />
  </when>
</choose>
```

`<outbound>` 區段做 chunk math（每 chunk **80,000 chars**），然後**靜態展開** 1 + 16 + 16 = 33 個 `<log-to-eventhub>` 元素：

```xml
<!-- 1 × summary -->
<log-to-eventhub logger-id="eh-logger-solutionc">@{ ... return JObject(kind=summary, ...).ToString(); }</log-to-eventhub>

<!-- 16 × request-body 靜態展開 i = 0..15 -->
<log-to-eventhub logger-id="eh-logger-solutionc">@{
  var i = 0;
  if (i >= total) { return "{\"kind\":\"skip\"}"; }    // ⚠️ 重要：不能 return ""
  var chunk = body.Substring(i*size, ...);
  return new JObject("kind", "request-body", "chunkIndex", i, "chunkTotal", total, "payload", chunk).ToString();
}</log-to-eventhub>
... (i = 1, 2, ..., 15) ...

<!-- 16 × response-body 同上 -->
```

事件結構（寫入 EH 的 JSON，每個事件被 Capture 包進 Avro Body 欄位）：

```jsonc
// summary
{
  "kind": "summary",
  "correlationId": "<X-Run-Id 或 GUID>",
  "timestamp": "...",
  "status": 200,
  "durationMs": 24983,
  "requestLength": 189,
  "responseLength": 339820,
  "requestChunks": 1,
  "responseChunks": 5,
  ...
}

// request-body / response-body chunks
{
  "kind": "response-body",
  "correlationId": "<X-Run-Id>",
  "chunkIndex": 0,
  "chunkTotal": 5,
  "payload": "...80,000 chars..."
}
```

### 優點

- **無 256KB 限制**：自動 chunk，最大 16 × 80,000 = 1.28 MB / request（已驗證 ~1MB streaming response）
- **完整 streaming**：response body 在 `<outbound>` 已組裝，SSE 全文照寫
- **長期歸檔**：Blob Capture Avro，配合 ADX external table 可秒級查詢數年資料
- **Header 隔離**：對既有方案 1 與一般流量零影響、可指定流量做高保真稽核
- **Retry 可見性**：APIM `<retry>` 每次嘗試都會產 1 組事件，可看到 429 → 200 完整路徑
- **MSI auth**：APIM 用 user-assigned MI 寫 EH，無金鑰流轉

### 限制與血淚教訓

| # | 限制 / 教訓 | 解法 / 說明 |
|---|---|---|
| **L1** | `<log-to-eventhub>` 每元素發送 **1** 條 EH 訊息 | 必須靜態展開 N 個 `<log-to-eventhub>`，沒有迴圈構造 |
| **L2** | EH 訊息 body 經 APIM 包裝後 ~**200KB** 截斷（不是文件說的 1MB） | chunk size 訂在 80,000 chars 留安全邊界 |
| **L3** | `<log-to-eventhub>` expression 回傳 `""` 或 `null` 會丟 `"value field is required"` 並中斷後續所有 emit | 跳過的 chunk 改回傳 `{"kind":"skip"}` 小 stub |
| **L4** | APIM Razor 不接受單行 `if (cond) return x;` | 必須包 `{ ... }` |
| **L5** | APIM 不支援 policy 內定義 C# function | 全部 inline（每個 chunk 元素都重複表達式） |
| **L6** | EH 4 partitions 無 partition key → 同一 request 的事件分散到不同 blob | 驗證腳本要掃所有 partition 的同時段 blob |
| **L7** | Capture 預設 `skipEmptyArchives=false` → 空時段也會 508-byte Avro 頭 | 驗證需過濾 `len(raw) > 600` |
| **L8** | APIM `<retry>` 觸發時，每個 attempt 都產 1 組（summary + bodies） | 驗證腳本依 timestamp 排序 attempt，挑 2xx 為 canonical |
| **L9** | Foundry Kimi-K2.5 backend `concurrent capacity = 8` → 高頻 `429` | APIM `<retry>` 自動恢復；TC 設計時降頻 |
| **L10** | `kunlenewfoundry01` API 的 subscription key header 名是 `api-key`（不是 `Ocp-Apim-Subscription-Key`） | notebook 已用 `api-key` |

### 驗證腳本（notebook helper `verify_marker`）

`notebooks/test-solution-c-eventhub.ipynb` 提供 4 個 TC + helper：

| TC | 場景 | 驗證重點 |
|---|---|---|
| **C1** | 短 non-streaming | 1 summary + 1/1 request + 1/1 response chunk；token usage 完整 |
| **C2** | 大 non-streaming（>256KB） | response 拆 ≥ 2 chunk，總長 > Solution 1 截斷點 |
| **C3** | streaming SSE | 完整 SSE delta 拼回，含 reasoning_content + content + 最終 usage |
| **C4** | 控制組（**不**帶 header） | EH 找不到 marker → 證明 header 隔離有效 |

`verify_marker` 處理多種狀況：
1. **跨 partition 聚合**：掃 0/1/2/3 四 partition 同時段 blob
2. **Chunk 排序與完整性檢查**：依 `chunkIndex` 排序、檢查 indices 為 `0..chunkTotal-1`
3. **長度交叉驗證**：拼接後總 bytes 必須等於 `summary.responseLength`
4. **Retry-aware**：偵測多 summary → 印 Attempt Timeline，挑 2xx 為 canonical，body 依 length 對應
5. **Streaming 解析**：對拼接後的 SSE 做 1 次 walk，輸出 reasoning_content + content + usage

驗證輸出範例（TC-C3，332KB 串流）：

```
=== SUMMARY (chosen attempt for body parsing) ===
           status: 200
       durationMs: 24983
   responseLength: 339820
   responseChunks: 5

=== REQUEST BODY  (1 events (idx0:1 variant) · 1 chunks · ✅ COMPLETE · ✅ length matches summary) ===

=== RESPONSE BODY (5 events (idx0:1 variant · idx1:1 variant · ...) · 5 chunks · ✅ COMPLETE · ✅ length matches summary) ===
  reassembled total: 339820 chars
  [streaming] 845 SSE events · finish_reason=stop
  reasoning_content: 12345 chars
  content:           67890 chars
  usage (from final SSE chunk): {'prompt_tokens': 61, 'completion_tokens': 4000, 'total_tokens': 4061}
```

### 部署與套用

```powershell
# 1. 部署 EH + Storage + Logger（idempotent）
./scripts/deploy-eventhub-logging.ps1

# 2. 套用 Solution 2 policy 到指定 API
./scripts/apply-eventhub-policy.ps1 -ApiName kunlenewfoundry01

# 3. （需要時）回退到純 Solution 1
./scripts/apply-eventhub-policy.ps1 -ApiName kunlenewfoundry01 -Remove
```

---

## 客戶部署選項 (Solution 2 變體)

中央稽核 = 客戶端**不應**為了 log 而改 header。本 lab 提供的 header-keyed 版只是 POC / A-B 驗證用，**正式環境請直接採用 always-on（變體 A）**；變體 B / C 只是給特殊需求（少量豁免、tier 區隔）做參考，並非建議的預設。

### 變體比較

| 變體 | Policy 檔 | 觸發條件 | 用途 |
|---|---|---|---|
| **A. 永遠啟用（建議預設）** | `combined-llm-and-eventhub-policy-always-on.xml` | 所有請求一律寫 EH | **正式中央稽核部署**；client 完全不用改 |
| header-keyed (POC) | `combined-llm-and-eventhub-policy.xml` | 只在 `X-Logging-Channel: solution-c` 時觸發 | 僅供 lab POC / A-B 驗證 / 與方案 1 並存比對 |
| B. 反向 opt-out | 從 always-on 手動加 `<choose>` 判斷 `X-Logging-Channel == "off"` 略過 | 預設啟用，特定 client 帶 header 關閉 | 大多流量要記、少量內部 / health-check 流量豁免 |
| C. Subscription / Product 區隔 | 從 always-on 手動把條件換成 `context.Subscription.Id == "..."` 或 `context.Product.Id == "..."` | 依 subscription / product tier | Enterprise tier 強制稽核、Free tier 不記 |

### 變體 A — 永遠啟用（建議預設，已附 ready-to-use policy）

差異點僅 3 處：

1. `<inbound>` 拿掉 `<choose>/<when>...X-Logging-Channel...`，直接無條件設 `solc-enabled=true` 與抓 request body
2. `<outbound>` 拿掉 `<choose>/<when>...solc-enabled=="true"...` 外殼，內部 emit 邏輯不變
3. 頂端註解標示為 "ALWAYS ON — every request is logged to Event Hub"

套用方式：

```powershell
# 將 always-on 變體套到指定 API
./scripts/apply-eventhub-policy.ps1 -ApiName <api-id> -PolicyFile policies/combined-llm-and-eventhub-policy-always-on.xml
```

> ⚠️ `apply-eventhub-policy.ps1` 預設讀 `combined-llm-and-eventhub-policy.xml`；若 script 未支援 `-PolicyFile` 參數，可手動把 `$policyPath` 指到 always-on 檔，或在 portal 直接貼上。

### 變體 B / C 動手提示

從 always-on 版本起步：

```xml
<!-- 變體 B：預設啟用，header 為 "off" 時略過 -->
<choose>
  <when condition="@(context.Request.Headers.ContainsKey("X-Logging-Channel")
                   && context.Request.Headers["X-Logging-Channel"].FirstOrDefault() == "off")">
    <set-variable name="solc-enabled" value="false" />
  </when>
  <otherwise>
    <set-variable name="solc-enabled" value="true" />
    <!-- 抓 request body 等原有邏輯 -->
  </otherwise>
</choose>

<!-- 變體 C：依 subscription / product 區隔 -->
<when condition="@(context.Product != null && context.Product.Id == "enterprise")">
  ...
</when>
```

注意：變體 B/C 仍要**保留**原始 always-on 變體的 `<outbound>` 「無 `<choose>` 包裹」的展開（或恢復 `<choose>` 包裹但條件檢查 `solc-enabled` 變數），否則 emit 不會觸發。

### 客戶採用變體 A 的相依條件

| # | 項目 | 說明 |
|---|---|---|
| **D1** | `X-Run-Id` header | **不必要**。沒帶會 fallback 到 `context.RequestId`；客戶若要事後跨系統 join chunk 仍建議帶。 |
| **D2** | `api-key` header | **必要**。這是 APIM subscription key，做 API auth，與 logging 無關。 |
| **D3** | 效能影響 | 拿掉 header 隔離後，**所有**請求都跑 1 + 16 + 16 = 33 個 `<log-to-eventhub>` 元素，每個請求多 ~10–30ms latency 與 EH 流量。導入前建議在預期 TPS 下做負載測試。 |
| **D4** | EH / Storage 成本 | EH throughput unit、Storage Capture 容量會隨流量線性成長。若日均流量 > 100k req，建議改 EH Standard Dedicated 或調 retention 策略。 |
| **D5** | 與方案 1 並存？ | always-on 變體**技術上**仍保留 Solution 1 的 `<llm-emit-token-metric>` 與內建 LLM logging，因此會雙寫 EH 與 App Insights。**正式中央稽核建議二選一**：選定方案 2 後，可把 `<llm-emit-token-metric>` 與 API Diagnostic 的 `largeLanguageModel` 區塊移除，避免重複成本與資料分裂。 |

---

## 部署決策圖（三選一）

```
                        ┌── 純歷史相容 / 既有 App Insights Workbook 鎖定 ──→ 方案 1A（legacy，不建議新部署）
中央稽核需求 ─→ 評估 ───┤
                        ├── ⭐ 預設首選：body ≤ 2 MB（含 streaming SSE）─→ 方案 1B（GatewayLlmLogs，零 policy code）
                        │
                        └── body > 2 MB / 需離開 LAW（直進 ADX/Synapse）/ 永久 Blob 歸檔 ─→ 方案 2 (always-on)

方案 1A 路徑（legacy）:
  Client ──→ APIM (applicationinsights diagnostic) ──→ App Insights dependencies (≤256KB, streaming 只首封包)

方案 1B 路徑（⭐ 建議）:
  Client ──→ APIM (azuremonitor diagnostic, largeLanguageModel.logs=enabled)
                ↓
        Resource Log: GatewayLlmLogs ──→ LAW ApiManagementGatewayLlmLog table
                                        （多筆 row：seq=0 metadata, seq=1 request, seq≥2 response chunks，2 MB cap）

方案 2 路徑（always-on）:
  Client ──→ APIM (combined-llm-and-eventhub-policy-always-on.xml)
              ├─→ Backend (Foundry / OpenAI)
              └─→ Event Hub (aigw-llm-logs, MSI)
                    └─→ Blob Capture (Avro, 60s/10MB) ──→ ADX external table / notebook reassemble

⚠️ 本 lab 為了同時驗證所有方案，方案 2 policy 用 header-keyed 版讓多條路並存；
   正式部署選定其中一個套用即可（方案 1B 預設首選）。
```

---

## 如何選擇

回答以下流程：

1. **絕大多數情境（>95%）→ 方案 1B**：原生 chunk + SequenceNumber、原生 streaming SSE 重組、2 MB 上限、零 policy code。V1 實測對 Kimi-K2.5 streaming 也能拿到完整 reasoning content。
2. **以下任一條件成立 → 改走方案 2**：

   | 條件 | 方案 2 的理由 |
   |---|---|
   | 單條 prompt 或 completion 可能 > 2 MB | GatewayLlmLogs 硬上限是 2 MB；方案 2 只受 EH Standard 1 MB / message 限制，可任意 chunk |
   | 不能把對話內容寫進 LAW（合規 / 隔離 / 多租戶資料分離） | 方案 2 直接寫 EH → Blob，可選 customer-managed key、private endpoint，不經 LAW |
   | 需要 > 730 天的永久歸檔 | LAW 最大 retention 730 天；Blob 可永久（含 archive tier） |
   | 需要把對話直接餵 ADX / Synapse / Spark 做大規模分析、向量化、fine-tune 資料集 | Avro on Blob 是 ADX external table / Synapse Serverless 原生支援格式 |

3. **方案 1A 何時還用？** 只在「現有 App Insights Workbook / Alert 已鎖定 `dependencies` 表 schema 且短期不能改」的維護情境。新部署不要選。

> 計費聚合 / 容量規劃需求另從 Foundry 內建 `AzureMetrics`（**免費**，與三個方案皆不衝突）取得。

---

## 參考 commit history

| Commit | 說明 |
|---|---|
| `28f236f` | 方案 2 端到端打通（EH Capture + header 隔離） |
| `f65ad3c` | 修正 UTF-8 mojibake（body 抓 byte[] 而非 string） |
| `9015d7b` | verify_marker 跨 partition 聚合 |
| `141e156` | **重要**：chunk emit 用 skip-marker JSON 取代空字串（解決 chunk 1+ 不發送的 bug） |
| `791c8ae` | verify 改先聚合再列印（解決 TC-C3 輸出分散問題） |
| `9d28994` | verify 處理 APIM `<retry>` 多 attempt 場景 |
| `f090159` | 加入 SOLUTIONS.md（方案總覽） |
| `f458c9b` | 加入 always-on policy 變體 + 客戶部署選項章節 |
| `e59bab7` | 改寫為「二選一」框架 |
| `67450bb` | R1 根因修正（LAW dynamic 欄位上限） |
| _(本次)_ | **新增方案 1B（GatewayLlmLogs）** + V1 streaming SSE 實測結果，框架改為三選一 |
