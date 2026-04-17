# AI Gateway 統一架構方案

## 概述

透過 Azure API Management (APIM) 作為 AI Gateway，統一管理雲端與地端的所有 AI 模型推論請求。無論後端是 Azure OpenAI、Azure AI Foundry 雲端模型，或是地端自建的開源模型推論引擎，用戶端只需對接 APIM 一個入口，即可享有企業級治理能力。

## 架構圖

> 詳細架構圖請參考 [ai-gateway-architecture.drawio](ai-gateway-architecture.drawio)

```
                     用戶端 (OpenAI SDK / REST)
                              │
                              ▼
        ┌──────────────────────────────────────────────┐
        │           APIM AI Gateway（統一入口）          │
        │                                              │
        │  ┌────────────────────────────────────────┐  │
        │  │ 統一治理層                              │  │
        │  │ • llm-token-limit      (Token 限流)    │  │
        │  │ • llm-emit-token-metric (Token 監控)   │  │
        │  │ • rate-limit-by-key    (請求限流)      │  │
        │  │ • 認證 (API Key / OAuth / Managed ID)  │  │
        │  │ • 日誌 / 追蹤 (App Insights)           │  │
        │  └────────────────────────────────────────┘  │
        │                                              │
        │  ┌────────────────────────────────────────┐  │
        │  │ Backend Pool（負載均衡 / 智慧路由）     │  │
        │  └──┬────────────┬────────────┬───────────┘  │
        └─────┼────────────┼────────────┼──────────────┘
              │            │            │
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌───────────────────┐
        │  Azure   │ │ Azure AI │ │  地端推論引擎      │
        │  OpenAI  │ │ Foundry  │ │  (Self-Hosted GW) │
        │  (雲端)  │ │  (雲端)  │ │                   │
        │          │ │          │ │ Foundry Local      │
        │ GPT-4/5  │ │DeepSeek  │ │ vLLM / Ollama     │
        │ o-series │ │Llama-4   │ │ llama.cpp / TGI   │
        └──────────┘ └──────────┘ └───────────────────┘
```

## 三種後端類型

### 1. Azure OpenAI（雲端）

| 項目 | 說明 |
|------|------|
| **APIM API Type** | `AzureOpenAI` |
| **端點格式** | `/openai/deployments/{deployment-id}/chat/completions` |
| **認證方式** | Managed Identity |
| **支援模型** | GPT-4、GPT-5 系列、o-series 推理模型 |

### 2. Azure AI Foundry（雲端）

| 項目 | 說明 |
|------|------|
| **APIM API Type** | `AzureAI` |
| **端點格式** | `/models/chat/completions` |
| **認證方式** | Managed Identity |
| **支援模型** | DeepSeek-R1/V3、Llama-4、Mistral-Large-3、Grok、Cohere 等 Azure 直售的精選開源模型 |

### 3. 地端推論引擎（透過 Self-Hosted Gateway）

| 項目 | 說明 |
|------|------|
| **APIM API Type** | `OpenAI` 或 `PassThrough` |
| **端點格式** | `/v1/chat/completions`（OpenAI 相容） |
| **認證方式** | API Key 或無需認證 |
| **部署方式** | APIM Self-Hosted Gateway（Docker 容器）部署於地端，與推論引擎同一網路 |

## 地端推論引擎比較

| 特性 | Foundry Local | vLLM | Ollama | llama.cpp | TGI |
|------|---------------|------|--------|-----------|-----|
| **定位** | 微軟官方本地推論 | 高效能推論引擎 | 極簡本地部署 | 輕量 CPU 推論 | HF 生產推論 |
| **OpenAI API** | ✅ `/v1/chat/completions` | ✅ | ✅ | ✅ | ✅ |
| **預設端口** | `localhost:5273` | `localhost:8000` | `localhost:11434` | 自訂 | `localhost:8080` |
| **模型格式** | ONNX | HF/GGUF | GGUF/HF | GGUF | HF |
| **硬體加速** | CPU/GPU/NPU（自動） | GPU (CUDA) | CPU/GPU | CPU 為主 | GPU |
| **SDK 大小** | ~20MB | 較大 | 中等 | 極小 | 較大 |
| **平台** | Win/Mac/Linux/Android | Linux 為主 | Win/Mac/Linux | 全平台 | Linux |

### 選擇建議

- **企業 Azure 生態整合** → Foundry Local（與 Azure Foundry Model Catalog 同源）
- **高吞吐 GPU 推論** → vLLM（PagedAttention，生產級效能）
- **快速原型 / 開發測試** → Ollama（一行指令啟動）
- **純 CPU / 邊緣裝置** → llama.cpp（GGUF 量化，極低資源需求）
- **HuggingFace 生態整合** → TGI（原生支援 HF 模型庫）

## APIM 配置對應

### Bicep 中的 API Type 設定

```bicep
@allowed([
  'AzureOpenAIV1'  // Azure OpenAI v1 格式
  'AzureOpenAI'    // Azure OpenAI 格式
  'AzureAI'        // Azure AI Model Inference API
  'OpenAI'         // 原生 OpenAI 格式（地端推論引擎適用）
  'PassThrough'    // 萬用通配路徑
])
param inferenceAPIType string = 'AzureOpenAI'
```

### 各後端 serviceUrl 設定

| 後端 | serviceUrl |
|------|-----------|
| Azure OpenAI | `https://{resource}.openai.azure.com` |
| Azure AI Foundry | `https://{resource}.services.ai.azure.com` |
| Foundry Local | `http://localhost:5273/v1` |
| vLLM | `http://localhost:8000/v1` |
| Ollama | `http://localhost:11434/v1` |
| llama.cpp | `http://localhost:8080/v1` |
| TGI | `http://localhost:8080/v1` |

## 統一治理能力

透過 APIM Policy，所有後端共享以下治理能力：

| 治理功能 | APIM Policy | 說明 |
|----------|-------------|------|
| **Token 限流** | `llm-token-limit` | 基於 Token 數量的速率限制 |
| **Token 監控** | `llm-emit-token-metric` | 發送 Token 使用量指標至 Azure Monitor |
| **請求限流** | `rate-limit-by-key` | 基於 Subscription / IP / 自訂 Key 的請求限流 |
| **認證** | `authentication-managed-identity` / `validate-jwt` | Managed Identity 或 JWT 驗證 |
| **日誌** | App Insights Diagnostics | 請求 / 回應日誌與追蹤 |
| **負載均衡** | Backend Pool | 多後端負載均衡與容錯切換 |

### ⚠️ 注意事項

- `llm-token-limit` 和 `llm-emit-token-metric` 依賴後端回應中的 `usage.prompt_tokens` / `completion_tokens` 欄位。vLLM、TGI、Ollama 預設回傳此資訊；llama.cpp 需確認版本支援。
- Streaming (SSE) 模式下，`llm-token-limit` 需搭配 `estimate-prompt-tokens="true"` 進行 Token 估算。
- 地端部署需透過 APIM Self-Hosted Gateway 或 VPN/ExpressRoute 確保 APIM 可達後端。

## 參考資料

- [Azure AI Foundry 官方模型清單](https://learn.microsoft.com/azure/ai-foundry/model-inference/concepts/models)
- [Azure AI Model Inference API](https://learn.microsoft.com/azure/ai-foundry/model-inference/)
- [APIM Self-Hosted Gateway](https://learn.microsoft.com/azure/api-management/self-hosted-gateway-overview)
- [Foundry Local](https://learn.microsoft.com/azure/ai-foundry/foundry-local/get-started)
- [AI Gateway Repo - SLM Self Hosting Lab](labs/slm-self-hosting/)
