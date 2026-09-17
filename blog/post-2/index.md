---
date: "2026-09-17 20:55:00 +02:00"
slug: "rig-provider-agnostic-llm-rust"
title: "用 Rust 和 rig 打造与提供商无关的 LLM 层"
description: "用 rig 在 Rust 里统一 Anthropic、OpenAI、Gemini、Ollama 等多个 LLM 提供商，并在此基础上加上用户和会话记忆。"
author: "春晏"
featured_image: featured.jpeg
category: "rust"
reading_time: '11'
---

## 每个提供商都有一套自己的客户端

这个项目从一开始就有个硬性要求：同时支持多个提供商的模型。

大部分和 LLM 打交道的项目，迟早都要面对同时对接多个提供商的问题——比如
Anthropic 和 OpenAI 都得支持，才能满足用户的需求。

一旦要支持不止一个 LLM 提供商，问题就不再是“怎么调用这个 API”，而是变成了
“怎么才能不让提供商的细节到处泄漏”。

在 smista.ai 里，我想要的集成至少要覆盖五个提供商：Anthropic、OpenAI、
Gemini、Ollama，以及任意兼容 OpenAI 接口的服务端。这套集成还得通过一个统一的
trait 暴露出去，这样路由那一层就完全不用关心背后到底是哪个提供商在处理请求。

这篇文章记录的是 `smista-providers` 在 **rig 0.42**（`rig-core` 和
`rig-agent`）上的实现方式。

## 封装 rig 的 CompletionClient

[rig](https://rig.rs) 给每个提供商都提供了一个 `CompletionClient`，它会构建出
提供商专属的 `CompletionModel`。我自己写的 `Agent<C>` 就包了这么一个：

```rust
pub struct Agent<C>
where
    C: CompletionClient,
{
    model: C::CompletionModel,
    preamble: String,
    internal_tool: Arc<dyn InternalTool>,
    internal_tool_definition: RigToolDefinition,
    descriptor: ModelDescriptor,
}
```

我刻意没有用 rig 自带的高阶 `Agent` 构建器和它内置的工具调用循环：我需要区分
两种工具调用——一种是我自己的记忆工具能当场执行的，另一种是必须交给路由层去
处理的（也就是模型自己声明的工具）。而我不能控制的循环，是没办法做这个区分的。
所以 `Agent` 只存了裸的 `CompletionModel` 和它自己的 preamble（系统提示词），
每一轮都会重新构建一个 `CompletionRequestBuilder`：

```rust
fn request_builder(
    &self,
    prompt: RigMessage,
    history: &[RigMessage],
    parameters: &ModelParameters,
    tools: Vec<ToolDefinition>,
    tool_choice: ToolChoice,
) -> CompletionRequestBuilder<C::CompletionModel> {
    let mut all_tools: Vec<RigToolDefinition> = tools.into_iter().map(into_rig_tool).collect();
    all_tools.push(self.internal_tool_definition.clone());

    let builder = self
        .model
        .completion_request(prompt)
        .preamble(self.preamble.clone())
        .messages(history.iter().cloned())
        .tools(all_tools)
        .temperature_opt(parameters.temperature.map(f64::from))
        .max_tokens_opt(parameters.max_tokens.map(u64::from))
        .additional_params_opt(additional_params(parameters));

    match into_rig_tool_choice(tool_choice) {
        Some(choice) => builder.tool_choice(choice),
        None => builder,
    }
}
```

每一次请求都会带上 agent 自己的 preamble，以及它的内部工具定义（也就是记忆
工具），再加上调用方传进来的其他工具。这样不管当前是第几轮对话，模型看到的
系统上下文始终是一致的。

## 从客户端到抽象的 Model

但从一个连接到 Gemini 或者 Anthropic 的客户端，到我这边的 `Agent` 结构体，
再到路由层能直接调用的东西，中间是怎么打通的？

rig 已经给每个提供商提供了专属的客户端，可以直接配置 API key、base URL 之类
的选项。这让我这边的抽象可以做得很薄：每个提供商只需要一个薄薄的 `*Model`
类型，里面包一个 `Agent<C>`，再实现我自己定义的 `Model` trait。

比如 Gemini 这边的模型是这样的：

```rust
pub struct GeminiModel {
    agent: Agent<GeminiClient>,
    descriptor: ModelDescriptor,
    reference: ModelReference,
}

impl GeminiModel {
    pub async fn new<S>(
        GeminiModelArgs { preamble, storage }: GeminiModelArgs<S>,
        authentication: &Authentication,
        descriptor: ModelDescriptor,
        scope: MemoryScope,
        preamble_segments: &[String],
    ) -> Result<Self, ProviderError>
    where
        S: MemoryStorage + 'static,
    {
        let reference = descriptor.reference();
        let api_key = authentication.require_api_key(Provider::Gemini, &reference.model)?;
        let client = GeminiClient::new(api_key.expose_secret())?;

        let agent = Agent::new(AgentArgs {
            completion_model: client,
            descriptor: descriptor.clone(),
            preamble,
            preamble_segments: preamble_segments.to_vec(),
            storage,
            scope,
        })
        .await?;

        Ok(Self { agent, descriptor, reference })
    }
}
```

Anthropic 和 Ollama 的客户端也是类似的写法，只是各自用自己的 rig 客户端。但
它们都实现了 `CompletionClient`，而这正是 `Agent<C>` 唯一需要的东西。`scope`
告诉记忆后端这个 agent 的读写操作属于哪个用户、哪个会话；`preamble_segments`
则让调用方可以往 preamble 里追加额外指令（比如技能、每轮的上下文），而模型这
一层完全不需要知道这些内容具体是什么。

## Agent 向 LLM 逐轮发送请求

`Agent::complete` 是内部工具调用和外部工具调用真正分岔的地方。它发出一轮请求，
如果模型这一轮要求的所有工具调用都是记忆工具能处理的，它就直接执行掉，并立刻
发起下一轮，而不是把这些工具调用交还给路由层：

```rust
pub async fn complete(&self, request: CompletionRequest) -> ProviderResult<CompletionResponse> {
    let CompletionRequest { messages, parameters, tools, tool_choice } = request;
    // ...构建 `history`，并把最后一条消息弹出作为 `prompt`...

    let mut usage = RigUsage::new();
    for _ in 0..MAX_INTERNAL_TOOL_TURNS {
        let response = self
            .request_builder(prompt.clone(), &history, &parameters, tools.clone(), tool_choice)
            .send()
            .await
            .map_err(|error| self.error(category_from_completion(&error), error.to_string()))?;
        usage += response.usage;

        // ...从 `response.choice` 里收集文本和工具调用...

        let all_internal = !tool_calls.is_empty()
            && tool_calls.iter().all(|call| call.function.name == self.internal_tool_definition.name);
        if !all_internal {
            // 至少有一个工具调用属于路由层：原样返回
            return Ok(CompletionResponse { /* ... */ });
        }

        // 这一轮的所有调用都是 agent 内部的：执行它们，然后继续循环
        let mut results = Vec::with_capacity(tool_calls.len());
        for call in &tool_calls {
            results.push(self.execute_internal_tool(call).await?);
        }
        history.push(prompt);
        history.push(RigMessage::Assistant { id: response.message_id.clone(), content: response.choice.clone() });
        prompt = RigMessage::User { content: results };
    }

    Err(self.error(ProviderErrorCategory::Unknown, "model exceeded the internal tool turn limit"))
}
```

`MAX_INTERNAL_TOOL_TURNS` 存在的唯一目的，是防止模型不停调用记忆工具而陷入死
循环；正常的记忆操作一到两轮就能解决。

`stream()` 是流式版本的对应实现：它调用 `.stream()` 而不是 `.send()`，并把
rig 的 `StreamedAssistantContent` 映射成我自己定义的 `StreamEvent`（文本增量、
工具调用开始/请求、用量、结束）。和 `complete()` 不同，流式模式下不会自己执行
任何工具——不管是不是内部工具，每个调用都会以 `StreamEvent::ToolCallRequested`
的形式抛出来，交给调用方决定怎么处理。不支持 `streaming` 能力的模型会退回
`complete()`，再把它那一份完整响应回放成一个很短的流。

> 这里贴出来的当然是简化过的版本。完整实现可以看
> [smista.ai 仓库里的 agent.rs](https://github.com/smista-ai/smista.ai/blob/main/crates/smista-providers/src/agent.rs)，
> 里面还包括如何从那些不会返回结构化工具调用、只会返回纯文本的提供商那里把
> 工具调用“抢救”回来，以及用量和计费是怎么算的。

## 用 rig 的 PortableTool 加上用户和会话记忆

LLM agent 的核心能力之一，就是能用上会话记忆和用户记忆。也就是说，我得能把
有意义的信息存下来，供当前会话复用，也供长期复用（比如用户偏好）。之后，
agent 还得能把这些记忆重新取出来用。

为此，我实现了一个 `MemoryStorage` trait 来提供这部分功能，再配一个 rig 的
`PortableTool`。

为了存储会话和用户数据，我定义了 `MemoryStorage` trait，在 smista.ai 里，它
后来是用 SurrealDB 实现的一个客户端。这个后端是一个长期存活、共享的单一句柄，
而不是为某个用户单独构造出来的东西：每次调用都会带上一个 `MemoryScope`
（一个 `user_id` 加一个 `session_id`），告诉后端这次操作是替谁做的。

首先，我定义了一个 `MemoryRecord`，作为记录每条记忆的实体，用一个 key 来唯一
标识每一份信息：

```rust
pub struct MemoryRecord {
    /// 不透明的、由后端定义的句柄，用来标识这条记录。把它传回
    /// `forget_*` 就能精确删除这一条。
    pub handle: String,
    /// 可选的主题。带 key 的记录会按 key 做 upsert，后写入的同 key
    /// 记录会替换旧的；不带 key 的记录则会一直累积下去。
    pub key: Option<String>,
    /// 被记住的事实内容。
    pub content: String,
}
```

然后我把这个类型作为 `MemoryStorage` 的核心类型：

```rust
pub trait MemoryStorage: Send + Sync {
    type Error: std::error::Error + Send + Sync + 'static;

    fn put_user_memory(
        &self,
        scope: MemoryScope,
        key: Option<String>,
        content: String,
    ) -> impl Future<Output = Result<MemoryRecord, Self::Error>> + Send;

    fn forget_user_memory(
        &self,
        scope: MemoryScope,
        handle: String,
    ) -> impl Future<Output = Result<(), Self::Error>> + Send;

    fn get_user_memories(
        &self,
        scope: MemoryScope,
        limit: Option<usize>,
    ) -> impl Future<Output = Result<Vec<MemoryRecord>, Self::Error>> + Send;

    fn get_user_memory_by_key(
        &self,
        scope: MemoryScope,
        key: String,
    ) -> impl Future<Output = Result<Option<MemoryRecord>, Self::Error>> + Send;
}
```

实际的 trait 之后还会对会话记录暴露同样的一套方法。

要收拢对用户记忆的操作，我需要一个工具。工具是暴露给模型的一个带类型的函数。
模型不会直接执行它，而是发出一个结构化的工具调用，由宿主应用决定要不要执行、
怎么执行。

`rig` 把这个概念暴露成 `PortableTool` trait：`description()` 和
`parameters()` 都是普通的同步方法，工具的定义是从它们推导出来的，而不是手写
出来的：

```rust
pub struct MemoryTool<S>
where
    S: MemoryStorage,
{
    /// 这个工具读写的共享后端。
    storage: Arc<S>,
    /// 这个工具的操作所限定的用户和会话。
    scope: MemoryScope,
}

impl<S> PortableTool for MemoryTool<S>
where
    S: MemoryStorage + 'static,
{
    const NAME: &'static str = "memory";

    type Args = MemoryArgs;
    type Output = String;
    type Error = MemoryToolError<S::Error>;

    fn description(&self) -> String {
        concat!(
            "Record or forget a memory addressed by `key`.\n\n",
            "Use scope `user` for durable facts about the user that should ",
            "persist across sessions (preferences, identity, long-lived ",
            "context). Use scope `session` for working memory tied to the ",
            "current session only.\n\n",
            "Operations:\n",
            "- `record`: store `value` under `key`, replacing any existing ",
            "fact filed under the same key.\n",
            "- `forget`: remove the fact filed under `key`.\n\n",
            "You do not need to recall memories: everything recorded is ",
            "already provided to you as context at the start of the turn."
        )
        .to_string()
    }

    fn parameters(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "op": {
                    "type": "string",
                    "enum": ["record", "forget"],
                    "description": "The operation to perform."
                },
                "scope": {
                    "type": "string",
                    "enum": ["user", "session"],
                    "description": "Which store to target: durable user memory or session-only working memory."
                },
                "key": {
                    "type": "string",
                    "description": "Topic the fact is filed under; reuse the same key to replace or forget it."
                },
                "value": {
                    "type": "string",
                    "description": "The fact to record. Required for `record`, ignored for `forget`."
                }
            },
            "required": ["op", "scope", "key"]
        })
    }

    async fn call(&self, args: MemoryArgs) -> Result<String, Self::Error> {
        let MemoryArgs { op, scope: store, key, value } = args;

        match op {
            MemoryOp::Record => {
                let value = value.ok_or(MemoryToolError::MissingValue)?;
                match store {
                    MemoryStore::User => {
                        self.storage.put_user_memory(self.scope, Some(key.clone()), value).await?;
                    }
                    MemoryStore::Session => {
                        self.storage.put_session_memory(self.scope, Some(key.clone()), value).await?;
                    }
                }
                Ok(format!("Recorded {} memory \"{key}\".", store.label()))
            }
            MemoryOp::Forget => match self.handle_for(store, key.clone()).await? {
                Some(handle) => {
                    match store {
                        MemoryStore::User => self.storage.forget_user_memory(self.scope, handle).await?,
                        MemoryStore::Session => self.storage.forget_session_memory(self.scope, handle).await?,
                    }
                    Ok(format!("Forgot {} memory \"{key}\".", store.label()))
                }
                None => Ok(format!("No {} memory found for \"{key}\".", store.label())),
            },
        }
    }
}
```

注意这里有两个不同层面的“scope”。`self.scope: MemoryScope` 是这个工具是
替**谁**工作的（构造时就定死的用户和会话）；而 `MemoryStore`（也就是 `op` 里的
`scope` 参数，`user` 或 `session`）是模型这次调用想动**哪个**存储。把它们拆成
两个不同的类型，就是为了不让这两个概念混到一起。

`description` 和 `parameters` 告诉 LLM 这个工具什么时候该用、它是干什么的、
怎么传参数；`call` 则是模型触发这个工具时真正执行的函数。

注意这个工具没有暴露“取回记忆”的操作。这是故意的：记忆的检索是在每一轮开始
之前由宿主完成的，取回来的记忆会被拼进 agent 的 preamble 里。模型可以记录或
遗忘记忆，但它不负责决定记忆检索是怎么运作的。

### 把记忆接入 Agent

到这一步，我就可以把 `MemoryStorage` 的实现传给 `Agent::new`，把工具和用户
的记忆记录一起挂上去。我把记忆工具自己留在手里——也就是 `Agent<C>` 上的
`internal_tool`——而不是交给 rig，这样 `complete()` 才能自己决定是执行它还是
转发给路由层：

```rust
pub async fn new<S>(
    AgentArgs { completion_model, descriptor, preamble, preamble_segments, storage, scope }: AgentArgs<C, S>,
) -> ProviderResult<Self>
where
    S: MemoryStorage + 'static,
{
    let model_name = descriptor.model.clone();
    let provider = descriptor.provider.clone();

    // 从记忆存储里加载 preamble，限定在这个用户和会话范围内
    let memory_preamble =
        load_memories_preamble(storage.as_ref(), scope, provider.clone(), &model_name).await?;

    // 加载记忆工具，限定范围方式相同
    let memory_tool = MemoryTool::new(storage.clone(), scope);

    // `preamble` 会替换掉系统提示词，所以记忆 preamble 和额外的 segment
    // 必须是追加而不是覆盖，否则会把原本的 preamble 冲掉。最终顺序是：
    // 基础 preamble，然后是记忆，然后是 segment。
    let mut full_preamble = preamble;
    if let Some(memories) = memory_preamble {
        full_preamble.push('\n');
        full_preamble.push_str(&memories);
    }
    for segment in &preamble_segments {
        full_preamble.push('\n');
        full_preamble.push_str(segment);
    }

    let internal_tool_definition = InternalTool::definition(&memory_tool);
    let model = completion_model.completion_model(model_name.clone());

    Ok(Self {
        model,
        preamble: full_preamble,
        internal_tool: Arc::new(memory_tool),
        internal_tool_definition,
        descriptor,
    })
}
```

`InternalTool` 是我自己写的一个小 trait，用来擦除我自己执行的每一个
`PortableTool` 的具体类型，这样 `Agent<C>` 就只需要在 completion client 上
泛型化，而不用管每个工具自己的泛型参数——毕竟记忆工具本身还是在它的
`MemoryStorage` 后端上泛型化的。

## 结语

rig 并没有让我省掉自己写抽象层的必要，但它把提供商相关的复杂度都推到了边缘。

每个提供商依然有自己的客户端、认证方式、模型名字和配置。但只要一个客户端实现
了 `CompletionClient`，剩下的部分——不管是 smista.ai 的哪个模块——都能用同一个
`Agent`、挂同一个内部工具、注入同一份记忆 preamble、走同一条补全流程。

自己掌控轮次循环，而不是用 rig 内置的那一套，才让我能够区分对待内部工具调用
（记忆）和需要路由层介入的调用。`PortableTool` 把一个工具的定义和它的逻辑放
在同一个地方，不需要靠一次异步调用来描述自己。

这正是我想要的边界：该和提供商绑定的地方绑定，其余的地方尽量做到与提供商
无关。

完整实现在 smista.ai 仓库的
[smista-providers crate](https://github.com/smista-ai/smista.ai/tree/main/crates/smista-providers)
里可以找到。

参考资料：

- [rig.rs](https://rig.rs)
- [rig_core](https://docs.rs/rig_core)（`0.42`）
- [smista.ai](https://github.com/smista-ai/smista.ai)
