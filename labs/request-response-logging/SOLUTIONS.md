# AI Gateway Request/Response Logging — 方案總覽

本文件梳理在 APIM AI Gateway 層完整記錄 LLM **input/output 內容**（不只 token 數）所探討、實作與驗證過的所有方案，包含取捨、限制與血淚教訓。

---

## TL;DR — 方案最終結論

中央稽核情境下，方案 1 與方案 2 **二選一**部署（不會雙軌並行；一般不會要求 client 端去寫不同的 header）。

| # | 方案 | 適用 |
|---|---|---|
| 1 | APIM Built-in LLM Logging → App Insights | body 一律 ≤ 256KB、且**不需要**完整記錄 streaming 內容（如純 chat、非 reasoning model） |
| 2 | APIM `log-to-eventhub` → Event Hub → Blob Capture (Avro) | 任一條件成立：body 可能 > 256KB、需完整記錄 SSE streaming、需長期合規歸檔（>90 天） |

> 本 lab 為了能在同一座 APIM / 同一個 API 上同時驗證、A/B 比對兩個方案，把方案 2 policy 設計成 **header-keyed**（只在 `X-Logging-Channel: solution-c` 時觸發）；這只是 POC 上的便利性，**正式部署不需要 client 帶任何特殊 header**——直接套用 always-on 變體即可（見 [客戶部署選項](#客戶部署選項-solution-c-變體)）。

---

## 方案 1 — APIM Built-in LLM Logging → App Insights

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

### 限制（驅使方案 2 出現的原因）

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

## 方案 2 — APIM `log-to-eventhub` → Event Hub → Blob Capture (Avro)

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

## 部署決策圖（二選一）

```
                            ┌── 一般 chat、body < 256KB、無 streaming reasoning ──→ 方案 1
中央稽核需求 ──→ 評估 body / streaming / 歸檔 ─┤
                            └── 任一條件命中（>256KB / SSE / >90d 歸檔） ─────→ 方案 2 (always-on)

方案 1 路徑:
  Client ──→ APIM ──→ App Insights (LLMRequest/LLMResponse, ≤256KB)
                                  └─→ KQL / Workbook / Alert

方案 2 路徑（always-on，正式部署）:
  Client ──→ APIM (combined-llm-and-eventhub-policy-always-on.xml)
              ├─→ Backend (Foundry / OpenAI)
              └─→ Event Hub (aigw-llm-logs, MSI)
                    └─→ Blob Capture (Avro, 60s/10MB)
                          └─→ ADX external table / notebook reassemble by correlationId

⚠️ 本 lab 為了同時驗證兩個方案，使用 header-keyed 版讓兩條路在同一個 APIM 並存；
   正式部署不會這樣做——選定其中一個方案套用即可。
```

---

## 如何選擇

回答以下任一題若是 **YES**，請選方案 2；全部 NO，方案 1 即可。

| 問題 | YES → 方案 2 的理由 |
|---|---|
| 是否會出現 prompt + completion 任一邊 > 256KB（含長文件分析、長 context window）？ | 方案 1 會被截斷 |
| 是否使用 reasoning model（Kimi-K2.5、o1/o3、DeepSeek-R1）或大量 streaming（SSE）？ | 方案 1 只能拿到首封包 |
| 是否需要將完整對話歸檔 > 90 天（合規 / 法務）？ | App Insights 預設 90 天 retention |
| 是否需要把對話送進 ADX / Synapse 做大規模分析、向量化、或 fine-tune 資料集？ | Blob Capture 的 Avro 直接可被 ADX external table / Synapse Serverless 查 |

> 計費聚合 / 容量規劃需求另從 Foundry 內建 `AzureMetrics`（**免費**，與兩個方案皆不衝突）取得。

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
| _(本次)_ | 改寫為「二選一」框架（中央稽核情境下不雙軌並行） |
