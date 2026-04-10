from app.agent.defaults import (
    DEFAULT_AGENT_DISPLAY_NAME,
    DEFAULT_AGENT_MODEL,
    DEFAULT_AGENT_PROVIDER,
    DEFAULT_AGENT_SYSTEM_PROMPT,
)
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    Agent,
    User,
    Workspace,
    WorkspaceEntry,
    WorkspaceEntryType,
    WorkspaceMembership,
    WorkspaceMembershipRole,
)


async def create_workspace_for_user(
    database_session: AsyncSession,
    *,
    user: User,
    display_name: str,
    description: str | None = None,
    workspace_metadata: dict | None = None,
) -> Workspace:
    workspace = Workspace(
        owner_user_id=user.id,
        display_name=display_name,
        description=description,
        workspace_metadata=workspace_metadata or {},
    )
    database_session.add(workspace)
    await database_session.flush()

    workspace_membership = WorkspaceMembership(
        workspace_id=workspace.id,
        user_id=user.id,
        role=WorkspaceMembershipRole.owner,
    )
    default_agent = Agent(
        workspace_id=workspace.id,
        created_by_user_id=user.id,
        display_name=DEFAULT_AGENT_DISPLAY_NAME,
        provider=DEFAULT_AGENT_PROVIDER,
        model=DEFAULT_AGENT_MODEL,
        system_prompt=DEFAULT_AGENT_SYSTEM_PROMPT,
        agent_metadata={
            "created_automatically": True,
            "preferred_tools": ["move_cursor", "speak"],
        },
    )
    root_directory_entry = WorkspaceEntry(
        workspace_id=workspace.id,
        created_by_user_id=user.id,
        entry_name="/",
        entry_path="/",
        entry_type=WorkspaceEntryType.directory,
        entry_metadata={},
    )

    database_session.add(workspace_membership)
    database_session.add(default_agent)
    database_session.add(root_directory_entry)

    return workspace
