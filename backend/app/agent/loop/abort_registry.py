import asyncio
from dataclasses import dataclass, field
from datetime import UTC, datetime


@dataclass
class AgentRunState:
    run_id: str
    created_at: datetime = field(default_factory=lambda: datetime.now(UTC))
    abort_event: asyncio.Event = field(default_factory=asyncio.Event)
    task: asyncio.Task | None = None


class AgentAbortRegistry:
    def __init__(self) -> None:
        self._runs: dict[str, AgentRunState] = {}
        self._lock = asyncio.Lock()

    async def register_run(self, run_id: str) -> AgentRunState:
        async with self._lock:
            run_state = self._runs.get(run_id)
            if run_state is None:
                run_state = AgentRunState(run_id=run_id)
                self._runs[run_id] = run_state
            return run_state

    async def attach_task(self, run_id: str, task: asyncio.Task) -> None:
        async with self._lock:
            run_state = self._runs.get(run_id)
            if run_state is not None:
                run_state.task = task

    async def abort_run(self, run_id: str) -> bool:
        async with self._lock:
            run_state = self._runs.get(run_id)
            if run_state is None:
                return False

            run_state.abort_event.set()
            if run_state.task is not None:
                run_state.task.cancel()
            return True

    async def is_abort_requested(self, run_id: str) -> bool:
        async with self._lock:
            run_state = self._runs.get(run_id)
            return False if run_state is None else run_state.abort_event.is_set()

    async def unregister_run(self, run_id: str) -> None:
        async with self._lock:
            self._runs.pop(run_id, None)
