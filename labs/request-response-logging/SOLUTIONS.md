# AI Gateway Request/Response Logging — 方案總覽

本文件梳理在 APIM AI Gateway 層完整記錄 LLM **input/output 內容**（不只 token 數）所探討、實作與驗證過的所有方案，包含取捨、限制與血淚教訓。

---

## TL;DR — 方案最終結論

| # | 方案 | 狀態 | 適用場景 |
|---|---|---|---|
| ① | APIM Built-in LLM Logging → App Insights | ✅ **上線** | 一般流量；body ≤ 256KB；非 streaming 為佳 |
| ③ | Foundry Diagnostic Setting → Log Analytics | ❌ **已移除** | （只有 token count，不含內容；對稽核無價值） |
| C | APIM `log-to-eventhub` → Event Hub → Blob Capture (Avro) | ✅ **上線（header-keyed）** | 大 body / streaming / 長期歸檔；header 隔離不影響 ① |

**雙軌並行**：方案 ① 持續記錄所有流量到 App Insights；方案 C 只在 client 帶 `X-Logging-Channel: solution-c` header 時額外寫到 Event Hub，**對既有 ① 與一般流量零影響**。

---

## 方案 ① — APIM Built-in LLM Logging → App Insights

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

### 限制（驅使方案 C 出現的原因）

| # | 限制 | 影響 |
|---|---|---|
| **R1** | **單筆 message 上限 256KB**（hard cap，無法調高） | 大 prompt / 長 reasoning / 完整文件分析會被截斷 |
| **R2** | App Insights 採樣 / ingestion 延遲（~2 min） | 不適合即時稽核 |
| **R3** | App Insights retention 預設 90 天 | 長期歸檔需另外搬 |
| **R4** | **Streaming（SSE）僅記錄首封包** | TC-C3 場景下 reasoning content 完全看不到 |
| **R5** | 無法選擇性開關 — 全部 API / 全部請求都會寫 | 高流量成本壓力 |

### 驗證

`labs/request-response-logging/notebooks/test-logging.ipynb` — 跑 5 個 TC，KQL 查詢結果寫在 cell output。

---

## 方案 ③（已移除）— Foundry Diagnostic Setting

> **⚠️ 已從 lab 拔除（commit `6088a6f`）**

### 為什麼曾考慮

Microsoft.CognitiveServices/accounts 支援 Diagnostic Setting → Log Analytics，看似可以「直接從 Foundry 拿日誌」。

### 為什麼放棄（commit `4099ca9`）

| 項目 | 實況 |
|---|---|
| 表 `AzureDiagnostics` 內容 | 只有 HTTP metadata（URL / status / 延遲），**沒有 prompt / completion 文字** |
| 表 `AzureMetrics` 內容 | 只有 token **數量**（`processed_prompt_tokens` / `generated_completion_tokens`） |
| 適用場景 | 計費聚合 / 容量規劃 / 健康監控 |
| **不適用** | 內容稽核、Prompt 漏洞調查、合規 |

→ 對「企業中央稽核 = 看到完整對話內容」這個目標毫無幫助，留著反而誤導。

→ 計費聚合需求另用 Foundry 內建 `AzureMetrics`（**免費**、不需任何方案）。

---

## 方案 C — APIM `log-to-eventhub` → Event Hub → Blob Capture (Avro)

### 機制

```
Client (帶 X-Logging-Channel: solution-c)
  │
  ▼
APIM testaigw01 (combined-llm-and-eventhub-policy.xml)
  ├─ <inbound>  : 方案 ① 照舊（trace + emit-token-metric）
  │              + 若 header 命中 → 抓 request body 到 variable
  ├─ <backend>  : <retry> 處理 429/5xx
  └─ <outbound> : 方案 ① 照舊
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
- **Header 隔離**：對既有方案 ① 與一般流量零影響、可指定流量做高保真稽核
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
| **C2** | 大 non-streaming（>256KB） | response 拆 ≥ 2 chunk，總長 > Solution ① 截斷點 |
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

# 2. 套用 Solution C policy 到指定 API
./scripts/apply-eventhub-policy.ps1 -ApiName kunlenewfoundry01

# 3. （需要時）回退到純 Solution ①
./scripts/apply-eventhub-policy.ps1 -ApiName kunlenewfoundry01 -Remove
```

---

## 雙軌總圖

```
                              ┌─ X-Logging-Channel: solution-c ─→ Solution ① + Solution C
Client ──→ APIM testaigw01 ───┤
                              └─ (無 header)                  ─→ Solution ① only

Solution ① 路徑:
  APIM ──→ App Insights (LLMRequest/LLMResponse, ≤256KB)
                       └─→ KQL / Workbook / Alert

Solution C 路徑（只在 header 命中時並行寫）:
  APIM ──→ Event Hub (aigw-llm-logs, MSI)
              └─→ Blob Capture (Avro, 60s/10MB)
                    └─→ ADX external table / notebook reassemble by correlationId
```

---

## 何時用哪一個

| 情境 | 建議 |
|---|---|
| 一般 production 流量稽核 | 方案 ① 即可 |
| 大 prompt（文件分析、長 context） | 加 `X-Logging-Channel: solution-c` 走方案 C |
| Streaming reasoning model（Kimi-K2.5、o1/o3、DeepSeek-R1） | 加 header 走方案 C |
| 長期合規歸檔（>90 天） | 加 header 走方案 C → Blob 永久保存 |
| 計費聚合 / 容量規劃 | Foundry 內建 `AzureMetrics`（不用任何方案） |
| Prompt injection 調查 | 兩個都查（① 提供索引、C 提供完整內容） |

---

## 參考 commit history

| Commit | 說明 |
|---|---|
| `6088a6f` | 移除方案 ③，加入方案 C 骨架 |
| `28f236f` | 方案 C 端到端打通（EH Capture + header 隔離） |
| `f65ad3c` | 修正 UTF-8 mojibake（body 抓 byte[] 而非 string） |
| `9015d7b` | verify_marker 跨 partition 聚合 |
| `141e156` | **重要**：chunk emit 用 skip-marker JSON 取代空字串（解決 chunk 1+ 不發送的 bug） |
| `791c8ae` | verify 改先聚合再列印（解決 TC-C3 輸出分散問題） |
| `9d28994` | verify 處理 APIM `<retry>` 多 attempt 場景 |
