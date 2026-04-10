import enum
import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    LargeBinary,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


class TimestampedModel:
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )


class WorkspaceMembershipRole(str, enum.Enum):
    owner = "owner"
    editor = "editor"
    viewer = "viewer"


class WorkspaceEntryType(str, enum.Enum):
    directory = "directory"
    file = "file"


class WorkspaceContentType(str, enum.Enum):
    markdown = "markdown"
    pdf = "pdf"
    image = "image"
    text = "text"
    other = "other"


class WorkspaceLaunchState(str, enum.Enum):
    stopped = "stopped"
    running = "running"


class User(Base, TimestampedModel):
    __tablename__ = "users"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    authentication_subject_identifier: Mapped[str | None] = mapped_column(
        String(255),
        unique=True,
        index=True,
        nullable=True,
    )
    email_address: Mapped[str | None] = mapped_column(
        String(320),
        unique=True,
        index=True,
        nullable=True,
    )
    display_name: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    avatar_image_url: Mapped[str | None] = mapped_column(
        String(2048),
        nullable=True,
    )
    password_hash: Mapped[str | None] = mapped_column(
        String(512),
        nullable=True,
    )
    profile_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    owned_workspaces: Mapped[list["Workspace"]] = relationship(
        back_populates="owner_user",
    )
    workspace_memberships: Mapped[list["WorkspaceMembership"]] = relationship(
        back_populates="user",
    )
    auth_sessions: Mapped[list["AuthSession"]] = relationship(
        back_populates="user",
        cascade="all, delete-orphan",
    )
    created_workspace_entries: Mapped[list["WorkspaceEntry"]] = relationship(
        back_populates="created_by_user",
    )


class Workspace(Base, TimestampedModel):
    __tablename__ = "workspaces"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    display_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    description: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    workspace_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )
    launch_state: Mapped[WorkspaceLaunchState] = mapped_column(
        Enum(
            WorkspaceLaunchState,
            name="workspace_launch_state",
        ),
        default=WorkspaceLaunchState.stopped,
        nullable=False,
    )
    launched_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )
    last_opened_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    owner_user: Mapped["User"] = relationship(back_populates="owned_workspaces")
    workspace_memberships: Mapped[list["WorkspaceMembership"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )
    workspace_entries: Mapped[list["WorkspaceEntry"]] = relationship(
        back_populates="workspace",
        cascade="all, delete-orphan",
    )


class WorkspaceMembership(Base, TimestampedModel):
    __tablename__ = "workspace_memberships"
    __table_args__ = (
        UniqueConstraint(
            "workspace_id",
            "user_id",
            name="uq_workspace_memberships_workspace_user",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    role: Mapped[WorkspaceMembershipRole] = mapped_column(
        Enum(
            WorkspaceMembershipRole,
            name="workspace_membership_role",
        ),
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="workspace_memberships")
    user: Mapped["User"] = relationship(back_populates="workspace_memberships")


class WorkspaceEntry(Base, TimestampedModel):
    __tablename__ = "workspace_entries"
    __table_args__ = (
        UniqueConstraint(
            "workspace_id",
            "entry_path",
            name="uq_workspace_entries_workspace_path",
        ),
        Index(
            "ix_workspace_entries_workspace_parent",
            "workspace_id",
            "parent_entry_id",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspaces.id", ondelete="CASCADE"),
        nullable=False,
    )
    parent_entry_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("workspace_entries.id", ondelete="CASCADE"),
        nullable=True,
    )
    created_by_user_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    entry_name: Mapped[str] = mapped_column(
        String(255),
        nullable=False,
    )
    entry_path: Mapped[str] = mapped_column(
        String(4096),
        nullable=False,
    )
    entry_type: Mapped[WorkspaceEntryType] = mapped_column(
        Enum(
            WorkspaceEntryType,
            name="workspace_entry_type",
        ),
        nullable=False,
    )
    content_type: Mapped[WorkspaceContentType | None] = mapped_column(
        Enum(
            WorkspaceContentType,
            name="workspace_content_type",
        ),
        nullable=True,
    )
    mime_type: Mapped[str | None] = mapped_column(
        String(255),
        nullable=True,
    )
    size_bytes: Mapped[int | None] = mapped_column(
        BigInteger,
        nullable=True,
    )
    content_sha256: Mapped[str | None] = mapped_column(
        String(64),
        nullable=True,
    )
    text_content: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )
    binary_content: Mapped[bytes | None] = mapped_column(
        LargeBinary,
        nullable=True,
    )
    storage_object_key: Mapped[str | None] = mapped_column(
        String(2048),
        nullable=True,
    )
    entry_metadata: Mapped[dict] = mapped_column(
        JSONB,
        default=dict,
        nullable=False,
    )

    workspace: Mapped["Workspace"] = relationship(back_populates="workspace_entries")
    parent_entry: Mapped["WorkspaceEntry | None"] = relationship(
        remote_side="WorkspaceEntry.id",
        back_populates="child_entries",
    )
    child_entries: Mapped[list["WorkspaceEntry"]] = relationship(
        back_populates="parent_entry",
        cascade="all, delete-orphan",
    )
    created_by_user: Mapped["User | None"] = relationship(
        back_populates="created_workspace_entries",
    )


class AuthSession(Base, TimestampedModel):
    __tablename__ = "auth_sessions"

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
    )
    user_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    session_token_hash: Mapped[str] = mapped_column(
        String(64),
        unique=True,
        index=True,
        nullable=False,
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
    )
    last_used_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    user: Mapped["User"] = relationship(back_populates="auth_sessions")
