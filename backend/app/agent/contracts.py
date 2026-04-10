from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field


AgentMessageRole = Literal["user", "assistant", "tool"]
AgentProviderName = Literal["openai_responses", "openrouter_chat_completions"]
AgentRunStatus = Literal[
    "completed",
    "aborted",
    "awaiting_client_tools",
    "max_iterations_exceeded",
]


class AgentToolDefinition(BaseModel):
    name: str
    description: str = ""
    input_json_schema: dict[str, Any] = Field(default_factory=dict)
    strict: bool = False


class AgentToolCall(BaseModel):
    id: str
    name: str
    arguments_json: str = "{}"


class AgentInputImage(BaseModel):
    image_base64: str
    mime_type: str = "image/jpeg"
    label: str | None = None
    pixel_width: int = Field(ge=1)
    pixel_height: int = Field(ge=1)
    is_primary_focus: bool = False


class AgentMessage(BaseModel):
    role: AgentMessageRole
    content: str = Field(default="")
    name: str | None = None
    tool_call_id: str | None = None
    provider_response_id: str | None = None
    images: list[AgentInputImage] = Field(default_factory=list)
    tool_calls: list[AgentToolCall] = Field(default_factory=list)


class AgentToolResult(BaseModel):
    tool_call_id: str
    tool_name: str
    output_text: str
    is_error: bool = False


class AgentLoopRequest(BaseModel):
    run_id: str | None = None
    provider: AgentProviderName
    model: str | None = None
    system_message: str | None = None
    messages: list[AgentMessage] = Field(default_factory=list)
    tools: list[AgentToolDefinition] = Field(default_factory=list)
    max_iterations: int = Field(default=8, ge=1, le=32)
    tool_choice: Literal["auto", "none", "required"] = "auto"
    temperature: float | None = Field(default=None, ge=0, le=2)
    max_output_tokens: int | None = Field(default=None, ge=1)


class AgentAssistantTurn(BaseModel):
    assistant_message: AgentMessage
    tool_calls: list[AgentToolCall] = Field(default_factory=list)


class AgentLoopResponse(BaseModel):
    run_id: str
    status: AgentRunStatus
    provider: AgentProviderName
    model: str
    iterations_completed: int
    final_output_text: str
    messages: list[AgentMessage]
    tool_calls: list[AgentToolCall]
    tool_results: list[AgentToolResult]


class AbortAgentRunResponse(BaseModel):
    run_id: str
    was_found: bool
    is_abort_requested: bool


class AgentRunRegistration(BaseModel):
    run_id: str
    created_at: datetime
