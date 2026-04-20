# AI Gateway Request/Response Logging 測試

> 在 APIM AI Gateway 層統一記錄所有 LLM 請求的 input/output，支援 Chat Completions、Responses、Agent Service API 與 Streaming 場景。

## 📋 測試目標

驗證透過 Azure APIM AI Gateway，能否在 Gateway 層完整記錄每個請求的 input 與 output。

| API 類型 | 端點範例 | 驗證項目 |
|---------|---------|---------|
| Chat Completions | `/chat/completions` | Prompt、Completion、Token usage |
| Responses API | `/responses` | Input、Output、Reasoning |
| Agent Service API | `/assistants`、`/threads/{id}/runs` | Instructions、Messages、Tool calls |
| Streaming (SSE) | 上述三者 + `stream=true` | 分段回應的完整組合 |

## 🧩 測試環境（已透過 Azure CLI 確認）

| 資源 | 值 |
|------|---|
| Subscription ID | `fd50f208-ec1f-4985-85e0-5cb476436ca3` (kunle) |
| Resource Group | `newfoundry01` |
| APIM Name | `testaigw01` |
| APIM SKU | `BasicV2`（✅ 支援 LLM Logging） |
| Location | `East US 2` |
| API Name | `kunlenewfoundry01` |
| API Path | `/kunlenewfoundry01` |
| Operations | 通配 `/*` (所有 HTTP methods) — 涵蓋 Chat/Responses/Agent Service |
| Deployment | `Kimi-K2.5` |
| Model Endpoint | `https://testaigw01.azure-api.net/kunlenewfoundry01/openai/v1/` |

### 現有日誌配置狀態

| 項目 | 狀態 | 行動 |
|------|------|------|
| 服務層 Logger (`azuremonitor`) | ✅ 已存在（azureMonitor 類型，對應 Diagnostic Setting） | 保留 |
| Application Insights Logger | ❌ 未建立 | **需新建** |
| API 層 Diagnostic | ❌ 未設定 | **需新建**（含 `largeLanguageModel` 設定） |
| Log Analytics Workspace | ❌ RG 中無現有資源 | **需新建** |
| Application Insights | ❌ RG 中無現有資源 | **需新建** |

## 📐 文件導覽

| 文件 | 用途 |
|---|---|
| [`DECISION.md`](DECISION.md) ⭐ | **一頁式方案選擇決策** — 結論、為什麼選 1B、部署檢核表 |
| [`SOLUTIONS.md`](SOLUTIONS.md) | 三方案完整技術細節、policy 範例、KQL、限制與血淚教訓 |
| [`design.md`](design.md) | 原始架構設計（含資料流程、KQL 範例） |
| [`notebooks/test-solution-1b-llmlogs.ipynb`](notebooks/test-solution-1b-llmlogs.ipynb) | 方案 1B（首選）端到端驗證 — 5 TC |
| [`notebooks/test-solution-c-eventhub.ipynb`](notebooks/test-solution-c-eventhub.ipynb) | 方案 2 驗證（POC 用） |

> **目前首選方案：1B — APIM Built-in LLM Logging → Azure Monitor logger → Log Analytics `ApiManagementGatewayLlmLog`**。詳見 [`DECISION.md`](DECISION.md)。

## 📂 資料夾結構

```
labs/request-response-logging/
├── README.md                    # 本檔案
├── design.md                    # 詳細設計文件
├── bicep/
│   └── logging.bicep            # Log Analytics + App Insights 部署
├── policies/
│   ├── llm-logging-policy.xml   # LLM Logging + 自訂 trace policy
│   └── agent-logging-policy.xml # Agent Service 專用 policy
├── scripts/
│   ├── deploy-logging.ps1       # 部署 + 掛載 APIM Logger
│   └── apply-policy.ps1         # 套用 policy 到指定 API
├── notebooks/
│   └── test-logging.ipynb       # 測試用 Jupyter Notebook
└── kql/
    └── queries.kql              # 常用 KQL 查詢範例
```

## 🚀 執行步驟（概要）

```powershell
# 1. 部署 Log Analytics + App Insights 並掛載到 APIM
./scripts/deploy-logging.ps1

# 2. 套用 LLM Logging Policy
./scripts/apply-policy.ps1

# 3. 開啟測試 Notebook
code notebooks/test-logging.ipynb

# 4. 在 Azure Portal 或 Log Analytics 查詢日誌
# 參考 kql/queries.kql
```

## ✅ 驗收標準

- [ ] 三種 API 的 input（prompt/messages/instructions）均能在 App Insights 看到
- [ ] 三種 API 的 output（completion/response/tool_calls）均能在 App Insights 看到
- [ ] Streaming 請求的完整組合後內容可被記錄
- [ ] Token usage（prompt_tokens、completion_tokens）正確記錄
- [ ] 可透過 KQL 根據 correlation ID 查詢完整對話

## ⚠️ 注意事項

- APIM Logger 與 Diagnostic Settings 是兩個獨立機制，需都配置
- Built-in LLM Logging 需 APIM v2 (StandardV2/PremiumV2) 或 2024-05 之後的版本
- Streaming 日誌依賴 `estimate-prompt-tokens="true"` 或 outbound 解析
- Agent Service API 的 `/assistants`、`/threads` 端點可能需透過自訂 policy 補強記錄
