from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
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
    root_directory_entry = WorkspaceEntry(
        workspace_id=workspace.id,
        created_by_user_id=user.id,
        entry_name="/",
        entry_path="/",
        entry_type=WorkspaceEntryType.directory,
        entry_metadata={},
    )

    database_session.add(workspace_membership)
    database_session.add(root_directory_entry)

    return workspace
