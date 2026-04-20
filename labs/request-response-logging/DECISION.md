# 方案選擇決策摘要 — AI Gateway Request/Response Logging

> 一頁式決策文件。完整背景、policy、KQL、限制細節 → [`SOLUTIONS.md`](SOLUTIONS.md)。

更新日期：2026-04-20  
適用環境：APIM `testaigw01` / API `kunlenewfoundry01` / LAW `log-aigw-5e3hqtbguevmo`

---

## 結論（TL;DR）

**首選方案 1B**（APIM Built-in LLM Logging → Azure Monitor logger → Log Analytics `ApiManagementGatewayLlmLog`）。

- 中央稽核情境**三選一**部署，不會多軌並行。
- Client 端**不需**帶任何特殊 header；零 policy 程式碼。
- 已在 V1 與 4+1 個 TC 端到端實測通過（含 streaming SSE 自動重組、500 KB 大 request chunking）。

| # | 方案 | 採用 | 一句話定位 |
|---|---|---|---|
| 1A | App Insights logger → `dependencies` | ❌ legacy / 不再建議新採用 | 256 KB cap、streaming SSE 只記首封包 |
| **1B** | **Azure Monitor logger → LAW `ApiManagementGatewayLlmLog`** | ✅ **首選** | 2 MB / message、原生 chunk + SequenceNumber 重組、streaming SSE 自動重組為完整 assistant content |
| 2 | `log-to-eventhub` → Event Hub → Blob (Avro) | ⚠️ 例外場景才用 | 單條 message > 2 MB、需離開 LAW、需永久 Blob 歸檔、或需自訂 sink/schema |

---

## 為什麼是方案 1B（vs 1A、vs 2）

### 對照方案 1A

| 維度 | 1A | **1B** | 結果 |
|---|---|---|---|
| 單筆 message 上限 | 256 KB | **2 MB**（8×） | ✅ 1B 勝 |
| Streaming SSE | 只首封包（~200 bytes） | **logger 端自動重組為完整 assistant content** | ✅ 1B 勝（決定性差異） |
| Chunking 機制 | 無，超過直接截斷 | `CorrelationId` + `SequenceNumber` 自動切並可重組 | ✅ 1B 勝 |
| Token usage | App Insights customMetrics | 表內原生 `PromptTokens` / `CompletionTokens` 欄位 | ✅ 1B 勝（schema 乾淨） |
| Stream 標記 | 無 | 表內 `IsStreamCompletion` bool | ✅ 1B 勝 |
| Retention | App Insights 預設 90 天 | LAW 預設 30 天，可調至 730 天 | 平手（看設定） |
| 部署複雜度 | 1 個 logger + 1 個 diagnostic | 同樣 1 個 logger + 1 個 diagnostic | 平手 |

> **R4 streaming-only-first-packet 是 1A 的致命限制**。Reasoning 模型（Kimi-K2.5、o1 系列）90% content 在 streaming delta 中，1A 等於完全看不到對話。1B logger 端會自動拼回 SSE delta，寫入時是乾淨的 `{"role":"assistant","content":"..."}`。

### 對照方案 2

| 維度 | **1B** | 2 |
|---|---|---|
| 部署 | 1 個 diagnostic 設定 | 6 步：建 EH namespace + EH + Storage + Capture + 自訂 policy + Avro 解析腳本 |
| 客戶端負擔 | 零 | POC 變體要帶 `X-Logging-Channel`；正式變體 always-on |
| 大 message（> 2 MB） | ❌ 截斷 | ✅ Event Hub 1 MB / event，policy 自動切 chunk |
| 永久歸檔 | ❌（LAW 最大 730 天） | ✅ Blob 歸檔可永久 |
| 直進 ADX / Synapse | ❌（需 LAW export） | ✅ Avro on Blob 可直 mount |
| Schema 自訂 | ❌ APIM 固定 schema | ✅ 自由設計 envelope |
| 維運成本 | LAW ingest GB | EH throughput unit + Storage + LAW（若 mirror）|

> **方案 2 只在以下情境才採用**（任一條件成立即可）：
> - 單條 message > 2 MB（極少見，需要 ≥500K token prompt）
> - 必須直進 ADX / Synapse / 自家數據湖，不經過 LAW
> - 監管要求 > 730 天 retention 或永久 Blob WORM 歸檔
> - 需要自訂 envelope schema（如加掛 tenant ID、business unit）

---

## 部署檢核表（採用方案 1B）

新環境上線前確認：

- [ ] APIM SKU 為 **BasicV2 / StandardV2 / PremiumV2**（v1 SKU 不支援 GatewayLlmLogs）
- [ ] LAW 已建立並設為 **Resource-specific (Dedicated) destination type** — 才會落到 `ApiManagementGatewayLlmLog`，否則只能用 legacy `AzureDiagnostics where Category=="GatewayLlmLogs"`，且 string 欄位被截在 ~15000 chars 而非 32 KB（V1 實測）
- [ ] APIM service-level Diagnostic Settings 啟用 `GatewayLlmLogs` category，sink → LAW
- [ ] **每個**要記錄的 API 加 API-level diagnostic（`loggerId=<APIM>/loggers/azuremonitor`、`largeLanguageModel.logs=enabled`、`maxSizeInBytes=32768`）
- [ ] 確認 client 端**不需**帶 `X-Logging-Channel`（這是方案 2 的 POC artifact）
- [ ] 跑 [`notebooks/test-solution-1b-llmlogs.ipynb`](notebooks/test-solution-1b-llmlogs.ipynb) 5 個 TC 全綠 → 上線

---

## 已知限制與規避（方案 1B）

| # | 限制 | 規避 |
|---|---|---|
| G1 | 單條 message 硬上限 **2 MB** | 99% LLM 對話夠用；觸發案例改走方案 2 |
| G2 | LAW 計費按 ingested GB | logger 端已去除 SSE wrapper，比 raw SSE 小 ~50×；高流量 API 監控成本曲線 |
| G3 | 必選 **Resource-specific (Dedicated)** destination type | Diagnostic Settings 建立時務必勾選；舊 deployment 若是 AzureDiagnostics legacy 需重建 |
| G4 | APIM `<retry>` 每次 attempt 產獨立 `CorrelationId` | 稽核查詢時要按 `OperationId` 群組（同一 client request）而非按 `CorrelationId` |
| G5 | 與 1A `applicationinsights` diagnostic 可共存 | 若選定 1B，建議移除 1A diagnostic 與 App Insights logger 以省成本 |

---

## 端到端驗證 — 5 個 TC（已於 testaigw01 全綠）

| TC | 場景 | 重點驗證 |
|---|---|---|
| TC-1B-1 | 短 non-streaming | 3 筆 row、isStream=false、content 非空 |
| TC-1B-2 | 大 non-streaming（>3500 token 中文長文） | response 切成 ≥2 個 seq≥2 chunk、重組長度合理 |
| TC-1B-3 | streaming SSE（Kimi-K2.5 reasoning） | **isStream=true、logger 自動重組為乾淨 assistant content**（1A 在此只有 ~200 bytes） |
| TC-1B-4 | 對照組（marker 不存在） | 應拿到 not found，證明驗證腳本不誤報 |
| TC-1B-5 | 大 request chunking（~500 KB user message） | request 切成 ≥30 個 seq=1 chunk、重組長度 ≈ 送出長度 → 證明 G1 機制有效 |

完整 notebook：[`notebooks/test-solution-1b-llmlogs.ipynb`](notebooks/test-solution-1b-llmlogs.ipynb)

---

## 變更紀錄

| 日期 | 決策 | 觸發 |
|---|---|---|
| 2026-04 初 | 原採方案 1A + 方案 2 共存（POC 並行 A/B 測試） | Lab 起步 |
| 2026-04-20 | **改採方案 1B 為唯一首選** | V1 實測證明 1B 能完整重組 streaming SSE 與大 chunk，同時取代 1A 與多數 2 場景 |
| 2026-04-20 | 新增 TC-1B-5 大 request chunking 測試 | 驗證 G1 (2 MB cap) 機制有效 |

---

## 相關文件

- [`SOLUTIONS.md`](SOLUTIONS.md) — 三方案完整技術細節、policy 範例、KQL、血淚教訓
- [`design.md`](design.md) — 原始架構設計
- [`README.md`](README.md) — Lab 環境與資料夾結構
- [`notebooks/test-solution-1b-llmlogs.ipynb`](notebooks/test-solution-1b-llmlogs.ipynb) — 5 TC 端到端驗證
- [`notebooks/test-solution-c-eventhub.ipynb`](notebooks/test-solution-c-eventhub.ipynb) — 方案 2 驗證（POC 用）
